//! YouTube: sign-in (Google's OAuth device flow), a reusable stream to push
//! video to, one broadcast per go-live, and its live chat (streamed in, or
//! polled if streaming isn't available; sent with `liveChatMessages.insert`).
//!
//! Quota: every project gets 10,000 units a day. Going live costs about 200
//! (create + bind + end the broadcast), each chat message sent 50, and each
//! chat read 1, as does each viewer-count check.

use std::{
    collections::{HashSet, VecDeque},
    sync::Arc,
    time::Duration,
};

use anyhow::{Context, Result, anyhow, bail};
use chrono::{DateTime, Utc};
use futures_util::StreamExt;
use oauth2::{
    AuthType, ClientId, ClientSecret, DeviceAuthorizationUrl, EndpointNotSet, EndpointSet, RefreshToken, Scope,
    StandardDeviceAuthorizationResponse, TokenResponse, TokenUrl, basic::BasicClient,
};
use serde::{Deserialize, de::DeserializeOwned};
use serde_json::{Value, json};
use tokio::{sync::Mutex, task::JoinHandle, time::Instant};

use crate::{
    config::YouTubeConfig,
    events::Events,
    protocol::{Account, AccountState, ChatAuthor, ChatMessage, DeviceCode, Platform, Privacy},
    store::{Store, YouTubeAuth, YouTubeBroadcast, YouTubeStream},
};

const SCOPE: &str = "https://www.googleapis.com/auth/youtube";
const API: &str = "https://www.googleapis.com/youtube/v3";

type GoogleClient = BasicClient<EndpointNotSet, EndpointSet, EndpointNotSet, EndpointNotSet, EndpointSet>;

pub struct YouTube {
    oauth: GoogleClient,
    http: reqwest::Client,
    store: Arc<Store>,
    events: Events,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    refresh_token: Option<String>,
    access: Option<(String, Instant)>,
    channel: Option<Channel>,
    pending: Option<DeviceCode>,
    error: Option<String>,
    sign_in: Option<JoinHandle<()>>,
    chat: Option<JoinHandle<()>>,
}

#[derive(Clone)]
struct Channel {
    title: String,
    handle: Option<String>,
}

impl YouTube {
    pub fn new(config: YouTubeConfig, store: Arc<Store>, events: Events) -> Arc<YouTube> {
        let oauth = BasicClient::new(ClientId::new(config.client_id))
            .set_client_secret(ClientSecret::new(config.client_secret))
            .set_auth_type(AuthType::RequestBody)
            .set_device_authorization_url(
                DeviceAuthorizationUrl::new("https://oauth2.googleapis.com/device/code".into()).expect("valid URL"),
            )
            .set_token_uri(TokenUrl::new("https://oauth2.googleapis.com/token".into()).expect("valid URL"));
        let http = reqwest::Client::builder()
            // oauth2 wants redirects off.
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .expect("HTTP client");
        Arc::new(YouTube { oauth, http, store, events, inner: Mutex::default() })
    }

    /// Picks up the sign-in (and any broadcast in progress) from a previous run.
    pub async fn restore(self: &Arc<Self>) {
        let state = self.store.get();
        let Some(saved) = state.youtube else { return };
        {
            let mut inner = self.inner.lock().await;
            inner.refresh_token = Some(saved.refresh_token);
            inner.channel = Some(Channel { title: saved.title, handle: saved.handle });
        }
        if let Err(e) = self.access_token().await {
            tracing::warn!("couldn't restore YouTube sign-in: {e:#}");
            let mut inner = self.inner.lock().await;
            *inner = Inner { error: Some("YouTube sign-in expired. Connect again.".into()), ..Inner::default() };
            drop(inner);
            self.events.accounts_changed();
            return;
        }
        if let Some(chat_id) = state.youtube_broadcast.and_then(|b| b.live_chat_id) {
            self.start_chat(chat_id).await;
        }
    }

    pub async fn account(&self) -> Account {
        let inner = self.inner.lock().await;
        let state = match (&inner.channel, &inner.pending) {
            (Some(_), _) if inner.refresh_token.is_some() => AccountState::Connected,
            (_, Some(_)) => AccountState::Pending,
            _ => AccountState::Disconnected,
        };
        let connected = state == AccountState::Connected;
        Account {
            platform: Platform::Youtube,
            state,
            login: inner.channel.as_ref().filter(|_| connected).and_then(|c| c.handle.clone()),
            display_name: inner.channel.as_ref().filter(|_| connected).map(|c| c.title.clone()),
            pending: inner.pending.clone(),
            error: inner.error.clone(),
        }
    }

    pub async fn channel_title(&self) -> Option<String> {
        let inner = self.inner.lock().await;
        inner.refresh_token.as_ref().and(inner.channel.as_ref()).map(|c| c.title.clone())
    }

    // MARK: Sign-in

    /// Starts the device flow: the user opens google.com/device and enters the
    /// code; we finish in the background.
    pub async fn connect(self: &Arc<Self>) -> Result<DeviceCode> {
        let details: StandardDeviceAuthorizationResponse = self
            .oauth
            .exchange_device_code()
            .add_scope(Scope::new(SCOPE.into()))
            .request_async(&|r| oauth_http(self.http.clone(), r))
            .await
            .map_err(|e| anyhow!("Couldn't start YouTube sign-in: {}", describe_oauth_error(&e)))?;
        let code = DeviceCode {
            user_code: details.user_code().secret().clone(),
            verification_url: details.verification_uri().to_string(),
            expires_at: Utc::now() + details.expires_in(),
        };
        let this = self.clone();
        let task = tokio::spawn(async move {
            let result = this
                .oauth
                .exchange_device_access_token(&details)
                .request_async(&|r| oauth_http(this.http.clone(), r), tokio::time::sleep, None)
                .await;
            let outcome = match result {
                Ok(token) => this.signed_in(token).await,
                Err(e) => Err(anyhow!("YouTube sign-in didn't finish: {}", describe_oauth_error(&e))),
            };
            if let Err(e) = outcome {
                tracing::warn!("{e:#}");
                let mut inner = this.inner.lock().await;
                inner.pending = None;
                inner.error = Some(format!("{e:#}"));
                inner.sign_in = None;
                drop(inner);
                this.events.accounts_changed();
            }
        });
        let mut inner = self.inner.lock().await;
        if let Some(previous) = inner.sign_in.replace(task) {
            previous.abort();
        }
        inner.pending = Some(code.clone());
        inner.error = None;
        drop(inner);
        self.events.accounts_changed();
        Ok(code)
    }

    async fn signed_in(&self, token: oauth2::basic::BasicTokenResponse) -> Result<()> {
        let refresh = token
            .refresh_token()
            .ok_or_else(|| anyhow!("Google didn't return a refresh token"))?
            .secret()
            .clone();
        let access = token.access_token().secret().clone();
        let expires = Instant::now() + token.expires_in().unwrap_or(Duration::from_secs(3600));
        let channel = self.my_channel(&access).await?;
        tracing::info!("signed in to YouTube as {}", channel.title);
        self.store.update(|s| {
            s.youtube = Some(YouTubeAuth {
                refresh_token: refresh.clone(),
                channel_id: channel.id.clone(),
                title: channel.title.clone(),
                handle: channel.handle.clone(),
            })
        })?;
        let mut inner = self.inner.lock().await;
        inner.refresh_token = Some(refresh);
        inner.access = Some((access, expires));
        inner.channel = Some(Channel { title: channel.title, handle: channel.handle });
        inner.pending = None;
        inner.error = None;
        inner.sign_in = None;
        drop(inner);
        self.events.accounts_changed();
        Ok(())
    }

    pub async fn disconnect(&self) -> Result<()> {
        let refresh = {
            let mut inner = self.inner.lock().await;
            for task in [inner.sign_in.take(), inner.chat.take()].into_iter().flatten() {
                task.abort();
            }
            std::mem::take(&mut *inner).refresh_token
        };
        // Keep the stream: reconnecting the same channel reuses it, and
        // `stream()` makes a new one if it belongs to another channel.
        self.store.update(|s| {
            s.youtube = None;
            s.youtube_broadcast = None;
        })?;
        self.events.accounts_changed();
        if let Some(token) = refresh {
            let revoked = self.http.post("https://oauth2.googleapis.com/revoke").form(&[("token", token)]).send().await;
            if let Err(e) = revoked {
                tracing::warn!("couldn't revoke YouTube token: {e}");
            }
        }
        Ok(())
    }

    /// A current access token, refreshed when it's about to expire (they last an hour).
    async fn access_token(&self) -> Result<String> {
        let mut inner = self.inner.lock().await;
        if let Some((token, expires)) = &inner.access
            && *expires > Instant::now() + Duration::from_secs(5 * 60)
        {
            return Ok(token.clone());
        }
        let refresh = inner.refresh_token.clone().ok_or_else(|| anyhow!("YouTube isn't connected."))?;
        let token = self
            .oauth
            .exchange_refresh_token(&RefreshToken::new(refresh))
            .request_async(&|r| oauth_http(self.http.clone(), r))
            .await
            .map_err(|e| anyhow!("Couldn't refresh the YouTube sign-in: {}", describe_oauth_error(&e)))?;
        let access = token.access_token().secret().clone();
        let expires = Instant::now() + token.expires_in().unwrap_or(Duration::from_secs(3600));
        inner.access = Some((access.clone(), expires));
        Ok(access)
    }

    // MARK: Going live

    /// Creates a broadcast bound to our reusable stream and returns the RTMPS
    /// URL to push to. YouTube starts the broadcast when video arrives and
    /// ends it when video stops (auto start/stop).
    pub async fn start_broadcast(self: &Arc<Self>, title: &str, privacy: Privacy) -> Result<String> {
        // A broadcast left over from last time would otherwise sit in "Upcoming".
        self.end_broadcast().await;
        let stream = self.stream().await?;
        let title: String = title.trim().chars().take(100).collect();
        let body = json!({
            "snippet": {
                "title": if title.is_empty() { "Live".into() } else { title },
                "scheduledStartTime": Utc::now().to_rfc3339(),
            },
            "status": { "privacyStatus": privacy, "selfDeclaredMadeForKids": false },
            "contentDetails": {
                "enableAutoStart": true,
                "enableAutoStop": true,
                "latencyPreference": "low",
                "monitorStream": { "enableMonitorStream": false },
            },
        });
        let broadcast: Resource = self
            .call(reqwest::Method::POST, "liveBroadcasts", &[("part", "snippet,status,contentDetails")], Some(body))
            .await
            .context("Couldn't create the YouTube broadcast")?;
        let live_chat_id = broadcast.snippet.as_ref().and_then(|s| s.live_chat_id.clone());
        self.store.update(|s| {
            s.youtube_broadcast = Some(YouTubeBroadcast { id: broadcast.id.clone(), live_chat_id: live_chat_id.clone() })
        })?;
        let _: Value = self
            .call(
                reqwest::Method::POST,
                "liveBroadcasts/bind",
                &[("id", &broadcast.id), ("part", "id"), ("streamId", &stream.id)],
                None,
            )
            .await
            .context("Couldn't attach the YouTube broadcast to the stream")?;
        tracing::info!("created YouTube broadcast {}", broadcast.id);
        if let Some(chat_id) = live_chat_id {
            self.start_chat(chat_id).await;
        }
        Ok(stream.url)
    }

    /// Ends our broadcast, if any. One that never went live is deleted
    /// instead, so it doesn't linger as "Upcoming"; a finished one is kept.
    pub async fn end_broadcast(&self) {
        if let Some(chat) = self.inner.lock().await.chat.take() {
            chat.abort();
        }
        let Some(broadcast) = self.store.get().youtube_broadcast else { return };
        if let Err(e) = self.finish(&broadcast.id).await {
            tracing::warn!("couldn't end YouTube broadcast {}: {e:#}", broadcast.id);
        }
        if let Err(e) = self.store.update(|s| s.youtube_broadcast = None) {
            tracing::error!("{e:#}");
        }
    }

    async fn finish(&self, id: &str) -> Result<()> {
        let list: List<Resource> = self.call(reqwest::Method::GET, "liveBroadcasts", &[("part", "status"), ("id", id)], None).await?;
        let status = list.items.first().and_then(|b| b.status.as_ref()).map(|s| s.life_cycle_status.as_str());
        match status {
            Some("ready" | "created") => {
                let _: Value = self.call(reqwest::Method::DELETE, "liveBroadcasts", &[("id", id)], None).await?;
            }
            Some("testing" | "liveStarting" | "live") => {
                let _: Value = self
                    .call(
                        reqwest::Method::POST,
                        "liveBroadcasts/transition",
                        &[("id", id), ("broadcastStatus", "complete"), ("part", "status")],
                        None,
                    )
                    .await?;
            }
            _ => {}
        }
        Ok(())
    }

    /// Our reusable stream, created on first use. Its key never changes, so
    /// YouTube Studio shows it as "Parallax".
    async fn stream(&self) -> Result<YouTubeStream> {
        if let Some(saved) = self.store.get().youtube_stream {
            let list: List<Resource> =
                self.call(reqwest::Method::GET, "liveStreams", &[("part", "id"), ("id", &saved.id)], None).await?;
            if !list.items.is_empty() {
                return Ok(saved);
            }
        }
        let body = json!({
            "snippet": { "title": "Parallax" },
            "cdn": { "ingestionType": "rtmp", "resolution": "variable", "frameRate": "variable" },
            "contentDetails": { "isReusable": true },
        });
        let created: Resource = self
            .call(reqwest::Method::POST, "liveStreams", &[("part", "snippet,cdn,contentDetails,status")], Some(body))
            .await
            .context("Couldn't create a YouTube stream")?;
        let info = created.cdn.and_then(|c| c.ingestion_info).ok_or_else(|| anyhow!("YouTube didn't return an ingest address"))?;
        let base = info.rtmps_ingestion_address.unwrap_or(info.ingestion_address);
        let stream = YouTubeStream { id: created.id, url: format!("{}/{}", base.trim_end_matches('/'), info.stream_name) };
        self.store.update(|s| s.youtube_stream = Some(stream.clone()))?;
        Ok(stream)
    }

    /// People watching our broadcast now. `None` until YouTube reports a
    /// count, or if the channel hides it.
    pub async fn viewers(&self) -> Result<Option<i64>> {
        let Some(broadcast) = self.store.get().youtube_broadcast else { return Ok(None) };
        let list: List<Video> = self
            .call(reqwest::Method::GET, "videos", &[("part", "liveStreamingDetails"), ("id", &broadcast.id)], None)
            .await
            .context("Couldn't get the YouTube viewer count")?;
        Ok(viewer_count(list))
    }

    // MARK: Chat

    pub async fn has_chat(&self) -> bool {
        self.store.get().youtube_broadcast.is_some_and(|b| b.live_chat_id.is_some())
    }

    pub async fn send_chat(&self, text: &str) -> Result<()> {
        let chat_id = self
            .store
            .get()
            .youtube_broadcast
            .and_then(|b| b.live_chat_id)
            .ok_or_else(|| anyhow!("YouTube chat opens when you go live on YouTube."))?;
        let body = json!({
            "snippet": {
                "liveChatId": chat_id,
                "type": "textMessageEvent",
                "textMessageDetails": { "messageText": text.chars().take(200).collect::<String>() },
            },
        });
        let _: Value = self
            .call(reqwest::Method::POST, "liveChat/messages", &[("part", "snippet")], Some(body))
            .await
            .context("Couldn't send to YouTube chat")?;
        Ok(())
    }

    async fn start_chat(self: &Arc<Self>, chat_id: String) {
        let this = self.clone();
        let task = tokio::spawn(async move { this.run_chat(chat_id).await });
        if let Some(old) = self.inner.lock().await.chat.replace(task) {
            old.abort();
        }
    }

    /// Reads chat until it ends. Streams when YouTube allows it (lower latency,
    /// less quota); falls back to polling.
    async fn run_chat(&self, chat_id: String) {
        let mut reader = ChatReader { page_token: None, seen: Seen::default() };
        let mut streaming = true;
        let mut backoff = Duration::from_secs(1);
        tracing::info!("reading YouTube chat");
        loop {
            let started = Instant::now();
            let result = if streaming { self.stream_chat(&chat_id, &mut reader).await } else { self.poll_chat(&chat_id, &mut reader).await };
            match result {
                Ok(ChatEnd::Ended) => {
                    tracing::info!("YouTube chat ended");
                    return;
                }
                Ok(ChatEnd::Reconnect) => backoff = Duration::from_secs(1),
                Err(ChatError::StreamingUnavailable(why)) => {
                    tracing::info!("YouTube chat streaming unavailable ({why}); polling instead");
                    streaming = false;
                    continue;
                }
                Err(ChatError::Other(e)) => {
                    tracing::warn!("YouTube chat: {e:#}");
                    if started.elapsed() > Duration::from_secs(60) {
                        backoff = Duration::from_secs(1);
                    }
                }
            }
            tokio::time::sleep(backoff).await;
            backoff = (backoff * 2).min(Duration::from_secs(60));
        }
    }

    async fn stream_chat(&self, chat_id: &str, reader: &mut ChatReader) -> Result<ChatEnd, ChatError> {
        let token = self.access_token().await?;
        let mut query = vec![("liveChatId", chat_id.to_owned()), ("part", "id,snippet,authorDetails".into())];
        if let Some(page) = &reader.page_token {
            query.push(("pageToken", page.clone()));
        }
        let response = self
            .http
            .get(format!("{API}/liveChat/messages/stream"))
            .bearer_auth(token)
            .query(&query)
            .send()
            .await
            .map_err(|e| ChatError::Other(e.into()))?;
        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            let error = ApiErrorBody::parse_with_status(status, &body);
            if error.is_chat_over() {
                return Ok(ChatEnd::Ended);
            }
            // Anything but auth or quota trouble means this form isn't available to us.
            if !matches!(status.as_u16(), 401 | 403 | 429) || error.reason.as_deref() == Some("methodNotAllowed") {
                return Err(ChatError::StreamingUnavailable(format!("{status}: {}", error.message)));
            }
            return Err(ChatError::Other(anyhow!("{status}: {}", error.message)));
        }
        let mut body = response.bytes_stream();
        let mut frames = JsonFrames::default();
        while let Some(chunk) = body.next().await {
            let chunk = chunk.map_err(|e| ChatError::Other(e.into()))?;
            for value in frames.push(&chunk).map_err(ChatError::Other)? {
                let page: ChatPage = serde_json::from_value(value).map_err(|e| ChatError::Other(e.into()))?;
                if reader.take(page, &self.events) {
                    return Ok(ChatEnd::Ended);
                }
            }
        }
        Ok(ChatEnd::Reconnect)
    }

    async fn poll_chat(&self, chat_id: &str, reader: &mut ChatReader) -> Result<ChatEnd, ChatError> {
        loop {
            let mut query = vec![("liveChatId", chat_id), ("part", "id,snippet,authorDetails")];
            let page_token = reader.page_token.clone();
            if let Some(page) = &page_token {
                query.push(("pageToken", page));
            }
            let page: ChatPage = match self.call(reqwest::Method::GET, "liveChat/messages", &query, None).await {
                Ok(page) => page,
                Err(e) if e.downcast_ref::<ApiErrorBody>().is_some_and(ApiErrorBody::is_chat_over) => return Ok(ChatEnd::Ended),
                Err(e) => return Err(ChatError::Other(e)),
            };
            let wait = Duration::from_millis(page.polling_interval_millis.unwrap_or(5000).max(1000));
            if reader.take(page, &self.events) {
                return Ok(ChatEnd::Ended);
            }
            tokio::time::sleep(wait).await;
        }
    }

    // MARK: API

    async fn my_channel(&self, access: &str) -> Result<MyChannel> {
        let list: List<Resource> = self
            .request(access, reqwest::Method::GET, "channels", &[("part", "snippet"), ("mine", "true")], None)
            .await
            .context("Couldn't look up your YouTube channel")?;
        let channel = list.items.into_iter().next().ok_or_else(|| {
            anyhow!("This Google account has no YouTube channel. Create one at youtube.com, then connect again.")
        })?;
        let snippet = channel.snippet.unwrap_or_default();
        Ok(MyChannel { id: channel.id, title: snippet.title.unwrap_or_default(), handle: snippet.custom_url })
    }

    async fn call<T: DeserializeOwned>(
        &self,
        method: reqwest::Method,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Value>,
    ) -> Result<T> {
        let token = self.access_token().await?;
        self.request(&token, method, path, query, body).await
    }

    async fn request<T: DeserializeOwned>(
        &self,
        token: &str,
        method: reqwest::Method,
        path: &str,
        query: &[(&str, &str)],
        body: Option<Value>,
    ) -> Result<T> {
        let mut request = self.http.request(method, format!("{API}/{path}")).bearer_auth(token).query(query);
        request = match body {
            Some(body) => request.json(&body),
            // Google answers a bodyless POST without `Content-Length: 0` with
            // 411, and an empty body alone doesn't add the header.
            None => request.header(reqwest::header::CONTENT_LENGTH, 0),
        };
        let response = request.send().await?;
        let status = response.status();
        let text = response.text().await?;
        if !status.is_success() {
            return Err(ApiErrorBody::parse_with_status(status, &text).into());
        }
        // DELETE and some POSTs answer 204 with no body.
        serde_json::from_str(if text.trim().is_empty() { "null" } else { &text })
            .with_context(|| format!("unexpected response from YouTube {path}"))
    }
}

// MARK: Chat parsing

enum ChatEnd {
    Ended,
    Reconnect,
}

enum ChatError {
    StreamingUnavailable(String),
    Other(anyhow::Error),
}

impl From<anyhow::Error> for ChatError {
    fn from(e: anyhow::Error) -> ChatError {
        ChatError::Other(e)
    }
}

struct ChatReader {
    page_token: Option<String>,
    seen: Seen,
}

impl ChatReader {
    /// Emits a page's messages. Returns true once the chat has ended.
    fn take(&mut self, page: ChatPage, events: &Events) -> bool {
        if page.next_page_token.is_some() {
            self.page_token = page.next_page_token;
        }
        for item in page.items {
            if self.seen.insert(&item.id)
                && let Some(message) = chat_message(item)
            {
                events.chat(message);
            }
        }
        page.offline_at.is_some()
    }
}

/// Message IDs already shown, so a reconnect never repeats one.
#[derive(Default)]
struct Seen {
    set: HashSet<String>,
    order: VecDeque<String>,
}

impl Seen {
    fn insert(&mut self, id: &str) -> bool {
        if !self.set.insert(id.to_owned()) {
            return false;
        }
        self.order.push_back(id.to_owned());
        if self.order.len() > 2000
            && let Some(old) = self.order.pop_front()
        {
            self.set.remove(&old);
        }
        true
    }
}

/// Splits a streamed response into JSON values. Google streams a JSON array
/// (`[{...},\n{...}]`) a piece at a time; this also accepts values separated
/// by newlines.
#[derive(Default)]
struct JsonFrames {
    buffer: Vec<u8>,
}

impl JsonFrames {
    fn push(&mut self, bytes: &[u8]) -> Result<Vec<Value>> {
        self.buffer.extend_from_slice(bytes);
        let mut values = Vec::new();
        loop {
            let start = self.buffer.iter().position(|b| !matches!(b, b'[' | b']' | b',' | b' ' | b'\n' | b'\r' | b'\t'));
            let Some(start) = start else {
                self.buffer.clear();
                break;
            };
            let mut stream = serde_json::Deserializer::from_slice(&self.buffer[start..]).into_iter::<Value>();
            match stream.next() {
                Some(Ok(value)) => {
                    let end = start + stream.byte_offset();
                    self.buffer.drain(..end);
                    values.push(value);
                }
                Some(Err(e)) if e.is_eof() => break,
                Some(Err(e)) => bail!("bad chat stream data: {e}"),
                None => break,
            }
        }
        Ok(values)
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatPage {
    next_page_token: Option<String>,
    polling_interval_millis: Option<u64>,
    offline_at: Option<String>,
    #[serde(default)]
    items: Vec<ChatItem>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatItem {
    id: String,
    snippet: ChatSnippet,
    author_details: Option<AuthorDetails>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatSnippet {
    #[serde(rename = "type")]
    kind: String,
    has_display_content: Option<bool>,
    display_message: Option<String>,
    published_at: Option<DateTime<Utc>>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AuthorDetails {
    channel_id: String,
    display_name: String,
    profile_image_url: Option<String>,
    #[serde(default)]
    is_chat_owner: bool,
    #[serde(default)]
    is_chat_moderator: bool,
}

/// Text messages, Super Chats, memberships and the like; not deletions,
/// bans, or other bookkeeping events.
fn chat_message(item: ChatItem) -> Option<ChatMessage> {
    let text = item.snippet.display_message.filter(|t| !t.trim().is_empty())?;
    if item.snippet.has_display_content == Some(false) || item.snippet.kind == "tombstone" {
        return None;
    }
    let author = item.author_details?;
    Some(ChatMessage {
        id: item.id,
        platform: Platform::Youtube,
        author: ChatAuthor {
            id: author.channel_id,
            display_name: author.display_name,
            avatar_url: author.profile_image_url,
            is_owner: author.is_chat_owner,
            is_moderator: author.is_chat_moderator,
        },
        text,
        timestamp: item.snippet.published_at.unwrap_or_else(Utc::now),
    })
}

fn viewer_count(list: List<Video>) -> Option<i64> {
    list.items.into_iter().next()?.live_streaming_details?.concurrent_viewers?.parse().ok()
}

// MARK: API types

#[derive(Deserialize)]
struct List<T> {
    #[serde(default = "Vec::new")]
    items: Vec<T>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Resource {
    id: String,
    snippet: Option<Snippet>,
    status: Option<Status>,
    cdn: Option<Cdn>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
struct Snippet {
    title: Option<String>,
    custom_url: Option<String>,
    live_chat_id: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Status {
    #[serde(default)]
    life_cycle_status: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Video {
    live_streaming_details: Option<LiveStreamingDetails>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LiveStreamingDetails {
    /// A number, sent as a string.
    concurrent_viewers: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Cdn {
    ingestion_info: Option<IngestionInfo>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct IngestionInfo {
    stream_name: String,
    ingestion_address: String,
    rtmps_ingestion_address: Option<String>,
}

struct MyChannel {
    id: String,
    title: String,
    handle: Option<String>,
}

/// Google's error body: `{"error": {"code", "message", "errors": [{"reason"}]}}`.
#[derive(Debug)]
struct ApiErrorBody {
    message: String,
    reason: Option<String>,
}

impl ApiErrorBody {
    /// Like `parse`, but some failures come back as an HTML page; name the status instead.
    fn parse_with_status(status: reqwest::StatusCode, body: &str) -> ApiErrorBody {
        if body.trim_start().starts_with('<') {
            return ApiErrorBody { message: format!("YouTube returned {status}"), reason: None };
        }
        ApiErrorBody::parse(body)
    }

    fn parse(body: &str) -> ApiErrorBody {
        let value: Value = serde_json::from_str(body).unwrap_or(Value::Null);
        let error = &value["error"];
        let reason = error["errors"][0]["reason"].as_str().map(str::to_owned);
        let message = error["message"].as_str().map(str::to_owned).unwrap_or_else(|| body.chars().take(200).collect());
        let message = match reason.as_deref() {
            Some("liveStreamingNotEnabled") => {
                "Live streaming isn't enabled on this YouTube channel. Turn it on at youtube.com/features (it can take up to 24 hours).".into()
            }
            Some("quotaExceeded") => "The YouTube API's daily quota is used up. It resets at midnight Pacific time.".into(),
            _ => message,
        };
        ApiErrorBody { message, reason }
    }

    fn is_chat_over(&self) -> bool {
        matches!(self.reason.as_deref(), Some("liveChatEnded" | "liveChatNotFound" | "liveChatDisabled"))
    }
}

impl std::fmt::Display for ApiErrorBody {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ApiErrorBody {}

// MARK: OAuth plumbing

/// oauth2 brings its own HTTP types; this runs them through our reqwest client.
async fn oauth_http(http: reqwest::Client, request: oauth2::HttpRequest) -> Result<oauth2::HttpResponse, reqwest::Error> {
    let (parts, body) = request.into_parts();
    let response = http.request(parts.method, parts.uri.to_string()).headers(parts.headers).body(body).send().await?;
    let mut out = oauth2::HttpResponse::new(Vec::new());
    *out.status_mut() = response.status();
    *out.headers_mut() = response.headers().clone();
    *out.body_mut() = response.bytes().await?.to_vec();
    Ok(out)
}

fn describe_oauth_error<RE: std::error::Error + 'static, T: oauth2::ErrorResponse + 'static>(
    e: &oauth2::RequestTokenError<RE, T>,
) -> String {
    match e {
        oauth2::RequestTokenError::ServerResponse(r) => {
            let text = r.to_string();
            if text.contains("invalid_grant") {
                "the sign-in was revoked or expired. Connect again.".into()
            } else if text.contains("invalid_client") || text.contains("unauthorized_client") {
                "the server's YOUTUBE_CLIENT_ID/SECRET aren't a valid \"TVs and Limited Input devices\" client.".into()
            } else if text.contains("access_denied") {
                "access was denied.".into()
            } else if text.contains("expired_token") {
                "the code expired. Try again.".into()
            } else {
                text
            }
        }
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PAGE: &str = r#"{
      "kind": "youtube#liveChatMessageListResponse", "nextPageToken": "p2", "pollingIntervalMillis": 3000,
      "items": [
        {"id": "m1", "snippet": {"type": "textMessageEvent", "hasDisplayContent": true, "displayMessage": "hello!",
          "publishedAt": "2026-09-24T18:00:00.123Z", "textMessageDetails": {"messageText": "hello!"}},
         "authorDetails": {"channelId": "UC1", "displayName": "Ada", "profileImageUrl": "https://yt3.example/a.jpg",
          "isChatOwner": false, "isChatModerator": true, "isChatSponsor": false, "isVerified": false}},
        {"id": "m2", "snippet": {"type": "messageDeletedEvent", "hasDisplayContent": false, "displayMessage": ""},
         "authorDetails": {"channelId": "UC2", "displayName": "Mod"}},
        {"id": "m3", "snippet": {"type": "superChatEvent", "hasDisplayContent": true, "displayMessage": "$5.00 from Grace: great stream"},
         "authorDetails": {"channelId": "UC3", "displayName": "Grace", "isChatOwner": false, "isChatModerator": false}}
      ]
    }"#;

    #[test]
    fn maps_chat_items() {
        let page: ChatPage = serde_json::from_str(PAGE).unwrap();
        let messages: Vec<_> = page.items.into_iter().filter_map(chat_message).collect();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].text, "hello!");
        assert!(messages[0].author.is_moderator);
        assert_eq!(messages[0].author.avatar_url.as_deref(), Some("https://yt3.example/a.jpg"));
        assert_eq!(messages[1].text, "$5.00 from Grace: great stream");
    }

    #[test]
    fn splits_a_streamed_json_array_across_chunks() {
        let stream = format!("[{PAGE},\n{PAGE}\n]");
        let mut frames = JsonFrames::default();
        let mut values = Vec::new();
        for chunk in stream.as_bytes().chunks(37) {
            values.extend(frames.push(chunk).unwrap());
        }
        assert_eq!(values.len(), 2);
        assert_eq!(values[1]["nextPageToken"], "p2");
    }

    #[test]
    fn splits_newline_delimited_values() {
        let mut frames = JsonFrames::default();
        let values = frames.push(b"{\"a\":1}\n{\"a\":2}\n{\"a\":").unwrap();
        assert_eq!(values.len(), 2);
        assert_eq!(frames.push(b"3}").unwrap()[0]["a"], 3);
    }

    #[test]
    fn reads_the_viewer_count() {
        let count = |json: &str| viewer_count(serde_json::from_str(json).unwrap());
        assert_eq!(count(r#"{"items": [{"liveStreamingDetails": {"concurrentViewers": "52"}}]}"#), Some(52));
        // Hidden by the channel, or not live yet.
        assert_eq!(count(r#"{"items": [{"liveStreamingDetails": {"actualStartTime": "2026-09-24T18:20:00Z"}}]}"#), None);
        assert_eq!(count(r#"{"items": []}"#), None);
    }

    #[test]
    fn skips_messages_already_seen() {
        let events = Events::new();
        let mut rx = events.subscribe();
        let mut reader = ChatReader { page_token: None, seen: Seen::default() };
        reader.take(serde_json::from_str(PAGE).unwrap(), &events);
        reader.take(serde_json::from_str(PAGE).unwrap(), &events);
        let mut count = 0;
        while rx.try_recv().is_ok() {
            count += 1;
        }
        assert_eq!(count, 2);
        assert_eq!(reader.page_token.as_deref(), Some("p2"));
    }

    #[test]
    fn explains_api_errors() {
        let body = r#"{"error": {"code": 403, "message": "The user is not enabled for live streaming.",
            "errors": [{"reason": "liveStreamingNotEnabled", "domain": "youtube.liveBroadcast"}]}}"#;
        let e = ApiErrorBody::parse(body);
        assert!(e.message.contains("youtube.com/features"));
        let html = ApiErrorBody::parse_with_status(reqwest::StatusCode::LENGTH_REQUIRED, "<!DOCTYPE html><html>…");
        assert_eq!(html.message, "YouTube returned 411 Length Required");
        let ended = ApiErrorBody::parse(r#"{"error": {"code": 403, "message": "ended", "errors": [{"reason": "liveChatEnded"}]}}"#);
        assert!(ended.is_chat_over());
    }
}
