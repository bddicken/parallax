//! The control API from docs/protocol.md: REST plus the `/v1/events` WebSocket.

use std::{sync::Arc, time::Duration};

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
use tokio::sync::{Mutex, broadcast::error::RecvError, watch};

use crate::{
    broadcast::{Broadcaster, Target},
    config::Config,
    events::Events,
    ingest::Ingest,
    protocol::{
        Account, AccountState, Destination, IngestInfo, Platform, SendChatRequest, ServerEvent, ServerHealth,
        StartBroadcastRequest, UpdateServerRequest,
    },
    store::Store,
    twitch::{self, Twitch},
    update, x,
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
    /// Set to true to stop the server gracefully (main.rs waits for it).
    pub shutdown: watch::Sender<bool>,
    /// Held while an update downloads, so only one runs at a time.
    pub updating: Mutex<()>,
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
        .route("/server/update", post(update_server))
        .layer(middleware::from_fn_with_state(state.clone(), require_token))
        // Added after the token layer, so it's open: the app polls it while a
        // new server boots.
        .route("/health", get(health));
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

async fn health(State(state): State<Arc<AppState>>) -> impl IntoResponse {
    Json(ServerHealth { version: update::VERSION.into(), can_update: state.config.release_repo.is_some() })
}

/// Installs another release and restarts into it. Needs a supervisor that
/// restarts the server when it exits (systemd, in the deploy).
async fn update_server(
    State(state): State<Arc<AppState>>,
    Json(req): Json<UpdateServerRequest>,
) -> AppResult<StatusCode> {
    let Some(repo) = &state.config.release_repo else {
        return Err(ApiError::bad_request(
            "This server can't update itself (PARALLAX_RELEASE_REPO isn't set). Servers deployed from Parallax can.",
        ));
    };
    if !update::is_version(&req.version) {
        return Err(ApiError::bad_request(format!("{:?} isn't a release version.", req.version)));
    }
    if state.broadcaster.status().await.live {
        return Err(ApiError(StatusCode::CONFLICT, "Stop the broadcast before updating the server.".into()));
    }
    let Ok(_updating) = state.updating.try_lock() else {
        return Err(ApiError(StatusCode::CONFLICT, "An update is already running.".into()));
    };
    update::install(repo, &req.version).await?;
    tracing::info!("installed parallax-server {}; restarting", req.version);
    // Give this response a moment to go out first.
    let shutdown = state.shutdown.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(500)).await;
        shutdown.send_replace(true);
    });
    Ok(StatusCode::ACCEPTED)
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
            chat_url: Some(twitch::chat_url(&login)),
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
            chat_url: youtube.chat_url(),
        });
    }
    if let Some(config) = &state.config.x {
        list.push(Destination {
            id: "x".into(),
            platform: Platform::X,
            name: "X".into(),
            enabled: true,
            rtmp_url: None,
            stream_key: None,
            chat_url: x::chat_url(config),
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
/// connected accounts (or, for X, the server's settings), so they're ignored
/// here. A missing stream key keeps the saved one.
async fn put_destinations(State(state): State<Arc<AppState>>, Json(list): Json<Vec<Destination>>) -> AppResult<StatusCode> {
    let mut custom = Vec::new();
    for mut d in list.into_iter().filter(|d| d.platform == Platform::Custom) {
        if d.id.is_empty() || d.id == "twitch" || d.id == "youtube" || d.id == "x" {
            return Err(ApiError::bad_request("Each custom destination needs its own id."));
        }
        if !d.rtmp_url.as_deref().is_some_and(|u| u.starts_with("rtmp://") || u.starts_with("rtmps://")) {
            return Err(ApiError::bad_request(format!("{}: rtmpURL must start with rtmp:// or rtmps://", d.name)));
        }
        d.chat_url = None;
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
            Platform::X => match &state.config.x {
                Some(config) => Ok(x::ingest_url(config)),
                None => Err("X isn't set up on the server.".into()),
            },
            Platform::Custom => {
                let base = dest.rtmp_url.clone().unwrap_or_default();
                Ok(match &dest.stream_key {
                    Some(key) if !key.is_empty() => format!("{}/{key}", base.trim_end_matches('/')),
                    _ => base,
                })
            }
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
    let mut shutdown = state.shutdown.subscribe();
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
            // Open sockets would otherwise hold up a graceful shutdown. (The
            // block drops `wait_for`'s guard, which isn't Send.)
            _ = async { drop(shutdown.wait_for(|stop| *stop).await) } => break,
        }
    }
    let _ = socket.send(Message::Close(None)).await;
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

#[cfg(test)]
mod tests {
    use axum::body::{Body, to_bytes};
    use tower::ServiceExt;

    use super::*;

    fn state(release_repo: Option<&str>) -> Arc<AppState> {
        let config = Arc::new(Config { release_repo: release_repo.map(Into::into), ..Config::for_tests() });
        let store = Arc::new(Store::open(&config.data_dir).unwrap());
        store.update(|s| s.api_token = "token".into()).unwrap();
        let events = Events::new();
        let ingest = Ingest::new(config.clone(), "key".into());
        let broadcaster = Broadcaster::new("ffmpeg".into(), ingest.clone(), events.clone());
        Arc::new(AppState {
            config,
            store,
            events,
            ingest,
            broadcaster,
            twitch: None,
            youtube: None,
            shutdown: watch::channel(false).0,
            updating: Mutex::new(()),
        })
    }

    async fn call(state: Arc<AppState>, request: axum::http::Request<Body>) -> (StatusCode, String) {
        let response = router(state).oneshot(request).await.unwrap();
        let status = response.status();
        let body = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (status, String::from_utf8(body.to_vec()).unwrap())
    }

    fn update_request(token: Option<&str>, version: &str) -> axum::http::Request<Body> {
        let mut request = axum::http::Request::post("/v1/server/update").header(header::CONTENT_TYPE, "application/json");
        if let Some(token) = token {
            request = request.header(header::AUTHORIZATION, format!("Bearer {token}"));
        }
        request.body(Body::from(format!(r#"{{"version":"{version}"}}"#))).unwrap()
    }

    #[tokio::test]
    async fn health_needs_no_token() {
        let (status, body) =
            call(state(Some("bddicken/parallax")), axum::http::Request::get("/v1/health").body(Body::empty()).unwrap())
                .await;
        assert_eq!(status, StatusCode::OK);
        let health: ServerHealth = serde_json::from_str(&body).unwrap();
        assert_eq!(health, ServerHealth { version: update::VERSION.into(), can_update: true });
    }

    #[tokio::test]
    async fn other_routes_still_need_the_token() {
        let (status, _) = call(state(None), axum::http::Request::get("/v1/status").body(Body::empty()).unwrap()).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let (status, _) = call(state(Some("bddicken/parallax")), update_request(None, "0.2.0")).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
    }

    #[tokio::test]
    async fn update_needs_a_release_repo_and_a_version() {
        let (status, body) = call(state(None), update_request(Some("token"), "0.2.0")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(body.contains("PARALLAX_RELEASE_REPO"), "{body}");
        let (status, body) = call(state(Some("bddicken/parallax")), update_request(Some("token"), "../x")).await;
        assert_eq!(status, StatusCode::BAD_REQUEST);
        assert!(body.contains("isn't a release version"), "{body}");
    }
}
