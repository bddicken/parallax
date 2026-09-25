mod api;
mod broadcast;
mod config;
mod events;
mod ingest;
mod protocol;
mod store;
mod twitch;
mod youtube;

use std::sync::Arc;

use anyhow::{Context, Result};
use tracing_subscriber::EnvFilter;

use crate::{
    api::AppState, broadcast::Broadcaster, config::Config, events::Events, ingest::Ingest, store::Store, twitch::Twitch,
    youtube::YouTube,
};

#[tokio::main]
async fn main() -> Result<()> {
    let _ = dotenvy::dotenv();
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()))
        .init();

    let mut config = Config::from_env()?;
    // Absolute, since MediaMTX runs with the data dir as its working directory.
    std::fs::create_dir_all(&config.data_dir).with_context(|| format!("creating {}", config.data_dir.display()))?;
    config.data_dir = config.data_dir.canonicalize()?;
    let config = Arc::new(config);
    let store = Arc::new(Store::open(&config.data_dir)?);
    if let Some(token) = &config.api_token {
        store.update(|s| s.api_token = token.clone())?;
    }
    let saved = store.get();
    let events = Events::new();

    let ingest = Ingest::new(config.clone(), saved.ingest_key.clone());
    tokio::spawn(ingest.clone().run());

    let twitch = config.twitch.clone().map(|c| Twitch::new(c, store.clone(), events.clone()));
    match &twitch {
        Some(twitch) => twitch.restore().await,
        None => tracing::warn!("TWITCH_CLIENT_ID isn't set, so Twitch is off"),
    }

    let youtube = config.youtube.clone().map(|c| YouTube::new(c, store.clone(), events.clone()));
    match &youtube {
        Some(youtube) => youtube.restore().await,
        None => tracing::warn!("YOUTUBE_CLIENT_ID/SECRET aren't set, so YouTube is off"),
    }

    let broadcaster = Broadcaster::new(config.ffmpeg_bin.clone(), ingest.clone(), events.clone());
    let state = Arc::new(AppState { config: config.clone(), store, events, ingest, broadcaster, twitch, youtube });
    tokio::spawn(api::publish_accounts(state.clone()));
    let app = api::router(state.clone());

    let listener = tokio::net::TcpListener::bind(config.addr).await.with_context(|| format!("listening on {}", config.addr))?;
    tracing::info!("parallax-server on http://{}", config.addr);
    tracing::info!("API token: {} (paste into Parallax › Settings › Server)", saved.api_token);
    axum::serve(listener, app).with_graceful_shutdown(shutdown()).await?;
    Ok(())
}

async fn shutdown() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    let mut term = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()).expect("SIGTERM handler");
    #[cfg(unix)]
    tokio::select! { _ = ctrl_c => {}, _ = term.recv() => {} }
    #[cfg(not(unix))]
    let _ = ctrl_c.await;
}
