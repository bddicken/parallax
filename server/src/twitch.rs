//! Twitch: sign-in (OAuth device code flow), the stream key, and chat
//! (EventSub over WebSocket to read, Helix to send). Only outbound
//! connections, so it works on a laptop with no public URL.

use std::{sync::Arc, time::Duration};

use anyhow::{Context, Result, anyhow, bail};
use chrono::Utc;
use futures_util::StreamExt;
use tokio::{sync::Mutex, task::JoinHandle, time::Instant};
use tokio_tungstenite::tungstenite::Message as WsMessage;
use twitch_api::{
    HelixClient,
    eventsub::{
        self, Event, EventsubWebsocketData, Transport,
        channel::{ChannelChatMessageV1, ChannelChatMessageV1Payload},
    },
    helix::streams::GetStreamsRequest,
};
use twitch_oauth2::{
    AccessToken, ClientSecret, RefreshToken, Scope, TwitchToken, UserToken, tokens::DeviceUserTokenBuilder,
};

use crate::{
    config::TwitchConfig,
    events::Events,
    protocol::{Account, AccountState, ChatAuthor, ChatMessage, DeviceCode, Platform},
    store::{Store, TwitchAuth},
};

const SCOPES: [Scope; 3] = [Scope::ChannelReadStreamKey, Scope::UserReadChat, Scope::UserWriteChat];

pub struct Twitch {
    config: TwitchConfig,
    /// For twitch_oauth2, which wants redirects off.
    http: reqwest::Client,
    helix: HelixClient<'static, reqwest::Client>,
    store: Arc<Store>,
    events: Events,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    token: Option<UserToken>,
    pending: Option<DeviceCode>,
    error: Option<String>,
    sign_in: Option<JoinHandle<()>>,
    chat: Option<JoinHandle<()>>,
}

impl Inner {
    fn stop_tasks(&mut self) {
        for task in [self.sign_in.take(), self.chat.take()].into_iter().flatten() {
            task.abort();
        }
    }
}

impl Twitch {
    pub fn new(config: TwitchConfig, store: Arc<Store>, events: Events) -> Arc<Twitch> {
        let http = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("HTTP client");
        Arc::new(Twitch {
            config,
            helix: HelixClient::with_client(http.clone()),
            http,
            store,
            events,
            inner: Mutex::default(),
        })
    }

    fn secret(&self) -> Option<ClientSecret> {
        self.config.client_secret.clone().map(ClientSecret::new)
    }

    /// Picks up the sign-in saved by a previous run, refreshing it if needed.
    pub async fn restore(self: &Arc<Self>) {
        let Some(saved) = self.store.get().twitch else { return };
        let result = match saved.refresh_token {
            Some(refresh) => {
                UserToken::from_existing_or_refresh_token(
                    &self.http,
                    AccessToken::new(saved.access_token),
                    RefreshToken::new(refresh),
                    self.config.client_id.clone().into(),
                    self.secret(),
                )
                .await
            }
            None => UserToken::from_existing(&self.http, AccessToken::new(saved.access_token), None, self.secret())
                .await
                .map_err(Into::into),
        };
        match result {
            Ok(token) => self.signed_in(token).await,
            Err(e) => {
                let why = explain(&e);
                tracing::warn!("couldn't restore Twitch sign-in: {why}");
                self.inner.lock().await.error = Some(why);
                self.publish().await;
            }
        }
    }

    pub async fn account(&self) -> Account {
        let inner = self.inner.lock().await;
        let (state, login) = match (&inner.token, &inner.pending) {
            (Some(t), _) => (AccountState::Connected, Some(t.login.to_string())),
            (None, Some(_)) => (AccountState::Pending, None),
            (None, None) => (AccountState::Disconnected, None),
        };
        Account {
            platform: Platform::Twitch,
            state,
            display_name: login.clone(),
            login,
            pending: inner.pending.clone(),
            error: inner.error.clone(),
        }
    }

    async fn publish(&self) {
        self.events.accounts_changed();
    }

    /// Starts the device code flow. The user enters the returned code at
    /// twitch.tv/activate, and we finish signing in in the background.
    pub async fn connect(self: &Arc<Self>) -> Result<DeviceCode> {
        let mut builder = DeviceUserTokenBuilder::new(self.config.client_id.clone(), SCOPES.to_vec());
        builder.set_secret(self.secret());
        let response = builder.start(&self.http).await.context("Couldn't start Twitch sign-in")?;
        let code = DeviceCode {
            user_code: response.user_code.clone(),
            verification_url: response.verification_uri.clone(),
            expires_at: Utc::now() + Duration::from_secs(response.expires_in),
        };
        let this = self.clone();
        let task = tokio::spawn(async move {
            match builder.wait_for_code(&this.http, tokio::time::sleep).await {
                Ok(token) => this.signed_in(token).await,
                Err(e) => {
                    tracing::warn!("Twitch sign-in failed: {e}");
                    let mut inner = this.inner.lock().await;
                    inner.pending = None;
                    inner.error = Some("Twitch sign-in didn't finish in time. Try again.".into());
                    drop(inner);
                    this.publish().await;
                }
            }
        });
        let mut inner = self.inner.lock().await;
        if let Some(previous) = inner.sign_in.replace(task) {
            previous.abort();
        }
        inner.pending = Some(code.clone());
        inner.error = None;
        drop(inner);
        self.publish().await;
        Ok(code)
    }

    pub async fn disconnect(&self) -> Result<()> {
        let token = {
            let mut inner = self.inner.lock().await;
            inner.stop_tasks();
            inner.pending = None;
            inner.error = None;
            inner.token.take()
        };
        self.store.update(|s| s.twitch = None)?;
        self.publish().await;
        if let Some(token) = token
            && let Err(e) = token.revoke_token(&self.http).await
        {
            tracing::warn!("couldn't revoke Twitch token: {e}");
        }
        Ok(())
    }

    async fn signed_in(self: &Arc<Self>, token: UserToken) {
        tracing::info!("signed in to Twitch as {}", token.login);
        if let Err(e) = self.save(&token) {
            tracing::error!("couldn't save Twitch sign-in: {e:#}");
        }
        let this = self.clone();
        let mut inner = self.inner.lock().await;
        inner.token = Some(token);
        inner.pending = None;
        inner.error = None;
        inner.sign_in = None;
        if let Some(old) = inner.chat.replace(tokio::spawn(async move { this.run_chat().await })) {
            old.abort();
        }
        drop(inner);
        self.publish().await;
    }

    fn save(&self, token: &UserToken) -> Result<()> {
        let auth = TwitchAuth {
            access_token: token.access_token.secret().to_owned(),
            refresh_token: token.refresh_token.as_ref().map(|r| r.secret().to_owned()),
            user_id: token.user_id.to_string(),
            login: token.login.to_string(),
        };
        self.store.update(|s| s.twitch = Some(auth))
    }

    /// A current access token, refreshed first if it's about to expire.
    /// Twitch access tokens last about four hours.
    async fn token(&self) -> Result<UserToken> {
        let mut inner = self.inner.lock().await;
        let token = inner.token.as_mut().ok_or_else(|| anyhow!("Twitch isn't connected."))?;
        if token.expires_in() < Duration::from_secs(10 * 60) {
            if let Err(e) = token.refresh_token(&self.http).await {
                bail!("Couldn't refresh the Twitch sign-in: {}", explain(&e));
            }
            // Refresh tokens can be single-use, so save the new one right away.
            self.save(token)?;
        }
        Ok(token.clone())
    }

    pub async fn is_connected(&self) -> bool {
        self.inner.lock().await.token.is_some()
    }

    pub async fn login(&self) -> Option<String> {
        self.inner.lock().await.token.as_ref().map(|t| t.login.to_string())
    }

    /// The RTMP(S) URL to push to, including the channel's stream key.
    pub async fn ingest_url(&self) -> Result<String> {
        let token = self.token().await?;
        let key = self.helix.get_stream_key(&token.user_id, &token).await.context("Couldn't get the Twitch stream key")?;
        Ok(format!("{}/{}", self.config.ingest_url.trim_end_matches('/'), key.as_str()))
    }

    /// People watching the channel now, or `None` if Twitch doesn't list it
    /// as live yet (it lags going live by up to a minute).
    pub async fn viewers(&self) -> Result<Option<i64>> {
        let token = self.token().await?;
        let request = GetStreamsRequest::user_ids(vec![token.user_id.clone()]);
        let response = self.helix.req_get(request, &token).await.context("Couldn't get the Twitch viewer count")?;
        Ok(response.data.first().map(|s| s.viewer_count as i64))
    }

    pub async fn send_chat(&self, text: &str) -> Result<()> {
        let token = self.token().await?;
        let response = self
            .helix
            .send_chat_message(&token.user_id, &token.user_id, text, &token)
            .await
            .context("Couldn't send to Twitch chat")?;
        if !response.is_sent {
            let reason = response.drop_reason.map(|r| r.message).unwrap_or_else(|| "no reason given".into());
            bail!("Twitch didn't post the message: {reason}");
        }
        Ok(())
    }

    // MARK: Chat

    /// Keeps a chat connection open while signed in, reconnecting with backoff.
    async fn run_chat(self: Arc<Self>) {
        let mut backoff = Duration::from_secs(1);
        loop {
            let started = Instant::now();
            if let Err(e) = self.chat_session().await {
                tracing::warn!("Twitch chat disconnected: {e:#}");
            }
            if started.elapsed() > Duration::from_secs(60) {
                backoff = Duration::from_secs(1);
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(Duration::from_secs(60));
        }
    }

    async fn chat_session(&self) -> Result<()> {
        let mut url = twitch_api::TWITCH_EVENTSUB_WEBSOCKET_URL.to_string();
        let mut subscribed = false;
        let mut previous = None;
        'connect: loop {
            let (mut ws, _) = tokio_tungstenite::connect_async(url.as_str()).await.context("connecting")?;
            // Twitch asks us to hold the old connection until the new one is up.
            drop(previous.take());
            let mut keepalive = Duration::from_secs(30);
            loop {
                let frame = tokio::time::timeout(keepalive + Duration::from_secs(10), ws.next())
                    .await
                    .context("no keepalive from Twitch")?
                    .ok_or_else(|| anyhow!("connection closed"))??;
                let text = match frame {
                    WsMessage::Text(text) => text,
                    WsMessage::Close(frame) => bail!("closed by Twitch: {frame:?}"),
                    _ => continue,
                };
                let data = match Event::parse_websocket(text.as_str()) {
                    Ok(data) => data,
                    Err(e) => {
                        tracing::debug!("skipping EventSub message: {e}");
                        continue;
                    }
                };
                match data {
                    EventsubWebsocketData::Welcome { payload, .. } => {
                        if let Some(seconds) = payload.session.keepalive_timeout_seconds {
                            keepalive = Duration::from_secs(seconds.max(1) as u64);
                        }
                        // After a reconnect the subscription carries over.
                        if !subscribed {
                            self.subscribe(&payload.session.id).await?;
                            subscribed = true;
                            tracing::info!("listening to Twitch chat");
                        }
                    }
                    EventsubWebsocketData::Reconnect { payload, .. } => {
                        url = payload.session.reconnect_url.ok_or_else(|| anyhow!("reconnect without a URL"))?.into_owned();
                        previous = Some(ws);
                        continue 'connect;
                    }
                    EventsubWebsocketData::Notification { payload: Event::ChannelChatMessageV1(p), .. } => {
                        if let eventsub::Message::Notification(message) = p.message {
                            self.events.chat(chat_message(message));
                        }
                    }
                    EventsubWebsocketData::Revocation { .. } => bail!("Twitch revoked chat access"),
                    _ => {}
                }
            }
        }
    }

    async fn subscribe(&self, session_id: &str) -> Result<()> {
        let token = self.token().await?;
        let condition = ChannelChatMessageV1::new(token.user_id.clone(), token.user_id.clone());
        self.helix
            .create_eventsub_subscription(condition, Transport::websocket(session_id), &token)
            .await
            .context("subscribing to Twitch chat")?;
        Ok(())
    }
}

/// Twitch's errors are buried a few sources deep; surface the useful ones.
fn explain(e: &(dyn std::error::Error + 'static)) -> String {
    let mut chain = Vec::new();
    let mut next = Some(e);
    while let Some(err) = next {
        chain.push(err.to_string());
        next = err.source();
    }
    let all = chain.join(": ");
    if all.contains("missing client secret") {
        "Your Twitch app is \"Confidential\", so the server needs its secret: set TWITCH_CLIENT_SECRET, restart, and connect again.".into()
    } else if all.contains("Invalid refresh token") || all.contains("invalid refresh token") {
        "Twitch sign-in expired. Connect again.".into()
    } else {
        format!("Twitch sign-in failed ({all}). Connect again.")
    }
}

fn chat_message(m: ChannelChatMessageV1Payload) -> ChatMessage {
    let has_badge = |id: &str| m.badges.iter().any(|b| b.set_id.as_str() == id);
    ChatMessage {
        id: m.message_id.to_string(),
        platform: Platform::Twitch,
        author: ChatAuthor {
            id: m.chatter_user_id.to_string(),
            display_name: m.chatter_user_name.to_string(),
            avatar_url: None,
            is_owner: m.chatter_user_id == m.broadcaster_user_id,
            is_moderator: has_badge("moderator"),
        },
        text: m.message.text,
        timestamp: Utc::now(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn maps_a_chat_notification() {
        // Trimmed from https://dev.twitch.tv/docs/eventsub/eventsub-reference/#channel-chat-message-event
        let frame = r##"{
          "metadata": {"message_id": "m1", "message_type": "notification", "message_timestamp": "2026-09-24T18:00:00.000Z",
                       "subscription_type": "channel.chat.message", "subscription_version": "1"},
          "payload": {
            "subscription": {"id": "s1", "status": "enabled", "type": "channel.chat.message", "version": "1",
                             "condition": {"broadcaster_user_id": "1971641", "user_id": "1971641"},
                             "transport": {"method": "websocket", "session_id": "abc"},
                             "created_at": "2026-09-24T17:00:00.000Z", "cost": 0},
            "event": {
              "broadcaster_user_id": "1971641", "broadcaster_user_login": "streamer", "broadcaster_user_name": "streamer",
              "chatter_user_id": "4145994", "chatter_user_login": "viewer32", "chatter_user_name": "viewer32",
              "message_id": "cc106a89-1814-919d-454c-f4f2f970aae7",
              "message": {"text": "Hi chat", "fragments": [{"type": "text", "text": "Hi chat", "cheermote": null, "emote": null, "mention": null}]},
              "color": "#00FF7F",
              "badges": [{"set_id": "moderator", "id": "1", "info": ""}],
              "message_type": "text", "cheer": null, "reply": null, "channel_points_custom_reward_id": null,
              "channel_points_animation_id": null, "source_broadcaster_user_id": null,
              "source_broadcaster_user_login": null, "source_broadcaster_user_name": null, "source_message_id": null,
              "source_badges": null, "is_source_only": null
            }
          }
        }"##;
        let EventsubWebsocketData::Notification { payload: Event::ChannelChatMessageV1(p), .. } =
            Event::parse_websocket(frame).unwrap()
        else {
            panic!("wrong event");
        };
        let eventsub::Message::Notification(m) = p.message else { panic!("not a notification") };
        let chat = chat_message(m);
        assert_eq!(chat.text, "Hi chat");
        assert_eq!(chat.author.display_name, "viewer32");
        assert!(chat.author.is_moderator);
        assert!(!chat.author.is_owner);
    }
}
