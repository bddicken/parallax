//! The control API from docs/protocol.md: REST plus the `/v1/events` WebSocket.

use std::sync::Arc;

use axum::{
    Json, Router,
    extract::{
        Path, Request, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    http::{HeaderMap, StatusCode, header},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{delete, get, post},
};
use tokio::sync::broadcast::error::RecvError;

use crate::{
    broadcast::{Broadcaster, Target},
    config::Config,
    events::Events,
    ingest::Ingest,
    protocol::{
        Account, AccountState, Destination, IngestInfo, Platform, SendChatRequest, ServerEvent, StartBroadcastRequest,
    },
    store::Store,
    twitch::Twitch,
    youtube::YouTube,
};

pub struct AppState {
    pub config: Arc<Config>,
    pub store: Arc<Store>,
    pub events: Events,
    pub ingest: Arc<Ingest>,
    pub broadcaster: Arc<Broadcaster>,
    pub twitch: Option<Arc<Twitch>>,
    pub youtube: Option<Arc<YouTube>>,
}

type AppResult<T> = Result<T, ApiError>;

pub fn router(state: Arc<AppState>) -> Router {
    let v1 = Router::new()
        .route("/status", get(status))
        .route("/ingest", get(ingest))
        .route("/destinations", get(destinations).put(put_destinations))
        .route("/broadcast/start", post(start))
        .route("/broadcast/stop", post(stop))
        .route("/chat/send", post(send_chat))
        .route("/accounts", get(accounts))
        .route("/accounts/{platform}/connect", post(connect_account))
        .route("/accounts/{platform}", delete(disconnect_account))
        .route("/events", get(events))
        .layer(middleware::from_fn_with_state(state.clone(), require_token));
    Router::new().route("/healthz", get(|| async { "ok" })).nest("/v1", v1).with_state(state)
}

async fn require_token(State(state): State<Arc<AppState>>, request: Request, next: Next) -> Response {
    let expected = state.store.get().api_token;
    let given = request
        .headers()
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .and_then(|v| v.strip_prefix("Bearer "));
    if given.is_some_and(|g| constant_time_eq(g.as_bytes(), expected.as_bytes())) {
        next.run(request).await
    } else {
        (StatusCode::UNAUTHORIZED, "Missing or wrong token.").into_response()
    }
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    a.len() == b.len() && a.iter().zip(b).fold(0, |acc, (x, y)| acc | (x ^ y)) == 0
}

async fn status(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(state.broadcaster.status().await)
}

async fn ingest(State(state): State<Arc<AppState>>, headers: HeaderMap) -> impl IntoResponse {
    // Send video to whatever host the client reached us at, unless configured.
    let host = state.config.public_host.clone().unwrap_or_else(|| {
        let authority = headers.get(header::HOST).and_then(|h| h.to_str().ok()).unwrap_or("127.0.0.1");
        match authority.rsplit_once(':') {
            Some((host, port)) if !port.contains(']') => host.to_owned(),
            _ => authority.to_owned(),
        }
    });
    // SRT listens on IPv4 only (see ingest.rs), and "localhost" may resolve to ::1.
    let host = if host == "localhost" { "127.0.0.1".to_owned() } else { host };
    Json(IngestInfo { srt_url: state.ingest.srt_url(&host), rtmp_url: state.ingest.rtmp_url(&host) })
}

async fn all_destinations(state: &AppState) -> Vec<Destination> {
    let mut list = Vec::new();
    if let Some(twitch) = &state.twitch
        && let Some(login) = twitch.login().await
    {
        list.push(Destination {
            id: "twitch".into(),
            platform: Platform::Twitch,
            name: format!("Twitch ({login})"),
            enabled: true,
            rtmp_url: None,
            stream_key: None,
        });
    }
    if let Some(youtube) = &state.youtube
        && let Some(title) = youtube.channel_title().await
    {
        list.push(Destination {
            id: "youtube".into(),
            platform: Platform::Youtube,
            name: format!("YouTube ({title})"),
            enabled: true,
            rtmp_url: None,
            stream_key: None,
        });
    }
    list.extend(state.store.get().custom_destinations);
    list
}

async fn destinations(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    let list = all_destinations(&state).await;
    Json(list.into_iter().map(|d| Destination { stream_key: None, ..d }).collect::<Vec<_>>())
}

/// Replaces the custom RTMP destinations. Platform destinations come from
/// connected accounts, so they're ignored here. A missing stream key keeps
/// the saved one.
async fn put_destinations(State(state): State<Arc<AppState>>, Json(list): Json<Vec<Destination>>) -> AppResult<StatusCode> {
    let mut custom = Vec::new();
    for mut d in list.into_iter().filter(|d| d.platform == Platform::Custom) {
        if d.id.is_empty() || d.id == "twitch" || d.id == "youtube" {
            return Err(ApiError::bad_request("Each custom destination needs its own id."));
        }
        if !d.rtmp_url.as_deref().is_some_and(|u| u.starts_with("rtmp://") || u.starts_with("rtmps://")) {
            return Err(ApiError::bad_request(format!("{}: rtmpURL must start with rtmp:// or rtmps://", d.name)));
        }
        if d.stream_key.is_none() {
            d.stream_key = state.store.get().custom_destinations.into_iter().find(|old| old.id == d.id).and_then(|old| old.stream_key);
        }
        custom.push(d);
    }
    state.store.update(|s| s.custom_destinations = custom)?;
    Ok(StatusCode::NO_CONTENT)
}

async fn start(State(state): State<Arc<AppState>>, Json(req): Json<StartBroadcastRequest>) -> AppResult<StatusCode> {
    if req.destination_ids.is_empty() {
        return Err(ApiError::bad_request("Pick at least one destination."));
    }
    let all = all_destinations(&state).await;
    let mut targets = Vec::new();
    for id in req.destination_ids.clone() {
        let Some(dest) = all.iter().find(|d| d.id == id) else {
            return Err(ApiError::bad_request(format!("Unknown destination {id}.")));
        };
        let url = match dest.platform {
            Platform::Twitch => match &state.twitch {
                Some(twitch) => twitch.ingest_url().await.map_err(|e| format!("{e:#}")),
                None => Err("Twitch isn't set up on the server.".into()),
            },
            Platform::Youtube => match &state.youtube {
                Some(youtube) => youtube
                    .start_broadcast(req.title.as_deref().unwrap_or_default(), req.privacy.unwrap_or_default())
                    .await
                    .map_err(|e| format!("{e:#}")),
                None => Err("YouTube isn't set up on the server.".into()),
            },
            Platform::Custom => {
                let base = dest.rtmp_url.clone().unwrap_or_default();
                Ok(match &dest.stream_key {
                    Some(key) if !key.is_empty() => format!("{}/{key}", base.trim_end_matches('/')),
                    _ => base,
                })
            }
            other => Err(format!("{other:?} isn't supported yet.")),
        };
        if let Err(error) = &url {
            tracing::warn!("can't go live on {id}: {error}");
        }
        targets.push(Target { id, url });
    }
    state.broadcaster.start(targets).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn stop(State(state): State<Arc<AppState>>) -> StatusCode {
    state.broadcaster.stop().await;
    if let Some(youtube) = &state.youtube {
        youtube.end_broadcast().await;
    }
    StatusCode::NO_CONTENT
}

async fn send_chat(State(state): State<Arc<AppState>>, Json(req): Json<SendChatRequest>) -> AppResult<StatusCode> {
    let text = req.text.trim();
    if text.is_empty() {
        return Err(ApiError::bad_request("Message is empty."));
    }
    let platforms = req.platforms.filter(|p| !p.is_empty());
    let wants = |p: Platform| platforms.as_ref().is_none_or(|list| list.contains(&p));
    // Send everywhere that can take it, then report what failed.
    let mut attempted = false;
    let mut failures = Vec::new();
    if let Some(twitch) = &state.twitch
        && wants(Platform::Twitch)
        && twitch.is_connected().await
    {
        attempted = true;
        if let Err(e) = twitch.send_chat(text).await {
            failures.push(format!("{e:#}"));
        }
    }
    if let Some(youtube) = &state.youtube
        && wants(Platform::Youtube)
        && youtube.has_chat().await
    {
        attempted = true;
        if let Err(e) = youtube.send_chat(text).await {
            failures.push(format!("{e:#}"));
        }
    }
    if !attempted {
        return Err(ApiError::bad_request(
            "No chat to send to. Connect Twitch in Settings › Server; YouTube chat opens when you go live there.",
        ));
    }
    if !failures.is_empty() {
        return Err(ApiError(StatusCode::BAD_GATEWAY, failures.join("\n")));
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn account_list(state: &AppState) -> Vec<Account> {
    let unconfigured = |platform, setting: &str| Account {
        platform,
        state: AccountState::Disconnected,
        login: None,
        display_name: None,
        pending: None,
        error: Some(format!("The server isn't set up for this yet (set {setting}).")),
    };
    vec![
        match &state.twitch {
            Some(twitch) => twitch.account().await,
            None => unconfigured(Platform::Twitch, "TWITCH_CLIENT_ID"),
        },
        match &state.youtube {
            Some(youtube) => youtube.account().await,
            None => unconfigured(Platform::Youtube, "YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET"),
        },
    ]
}

/// Sends the full account list whenever any platform's sign-in changes.
pub async fn publish_accounts(state: Arc<AppState>) {
    loop {
        state.events.wait_for_account_change().await;
        state.events.accounts(account_list(&state).await);
    }
}

async fn accounts(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(account_list(&state).await)
}

async fn connect_account(State(state): State<Arc<AppState>>, Path(platform): Path<Platform>) -> AppResult<impl IntoResponse> {
    let not_set_up = |setting: &str| ApiError::bad_request(format!("Set {setting} on the server first."));
    let code = match platform {
        Platform::Twitch => state.twitch.as_ref().ok_or_else(|| not_set_up("TWITCH_CLIENT_ID"))?.connect().await?,
        Platform::Youtube => {
            state.youtube.as_ref().ok_or_else(|| not_set_up("YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET"))?.connect().await?
        }
        other => return Err(ApiError::bad_request(format!("{other:?} accounts aren't supported yet."))),
    };
    Ok(Json(code))
}

async fn disconnect_account(State(state): State<Arc<AppState>>, Path(platform): Path<Platform>) -> AppResult<StatusCode> {
    match platform {
        Platform::Twitch if let Some(twitch) = &state.twitch => twitch.disconnect().await?,
        Platform::Youtube if let Some(youtube) = &state.youtube => youtube.disconnect().await?,
        _ => {}
    }
    Ok(StatusCode::NO_CONTENT)
}

async fn events(State(state): State<Arc<AppState>>, ws: WebSocketUpgrade) -> Response {
    ws.on_upgrade(move |socket| stream_events(state, socket))
}

/// Sends the current status and accounts, then every event as it happens.
async fn stream_events(state: Arc<AppState>, mut socket: WebSocket) {
    let mut rx = state.events.subscribe();
    let initial = [ServerEvent::Status(state.broadcaster.status().await), ServerEvent::Accounts(account_list(&state).await)];
    for event in initial {
        if send(&mut socket, &event).await.is_err() {
            return;
        }
    }
    loop {
        tokio::select! {
            event = rx.recv() => match event {
                Ok(event) => if send(&mut socket, &event).await.is_err() { return },
                // A slow client missed some chat; keep going.
                Err(RecvError::Lagged(n)) => tracing::warn!("events client lagged by {n}"),
                Err(RecvError::Closed) => return,
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Close(_))) | None | Some(Err(_)) => return,
                _ => {}
            },
        }
    }
}

async fn send(socket: &mut WebSocket, event: &ServerEvent) -> Result<(), axum::Error> {
    socket.send(Message::Text(serde_json::to_string(event).expect("serializable").into())).await
}

/// Errors become plain-text bodies, which the client shows as-is.
pub struct ApiError(StatusCode, String);

impl ApiError {
    fn bad_request(message: impl Into<String>) -> ApiError {
        ApiError(StatusCode::BAD_REQUEST, message.into())
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(e: anyhow::Error) -> ApiError {
        ApiError(StatusCode::BAD_GATEWAY, format!("{e:#}"))
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        (self.0, self.1).into_response()
    }
}
