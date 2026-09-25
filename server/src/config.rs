use std::{env, net::SocketAddr, path::PathBuf};

use anyhow::{Context, Result};

/// Settings from the environment (and `.env`, for local runs).
#[derive(Clone, Debug)]
pub struct Config {
    /// Where the control API listens.
    pub addr: SocketAddr,
    /// Holds `state.json` and the generated MediaMTX config.
    pub data_dir: PathBuf,
    /// Overrides the generated API token. Handy for scripted setups.
    pub api_token: Option<String>,
    /// Host name the client should send video to. Defaults to the host the
    /// client used to reach the API.
    pub public_host: Option<String>,
    pub srt_port: u16,
    pub rtmp_port: u16,
    pub mediamtx_api_port: u16,
    pub mediamtx_bin: String,
    pub ffmpeg_bin: String,
    pub twitch: Option<TwitchConfig>,
    pub youtube: Option<YouTubeConfig>,
    pub x: Option<XConfig>,
}

#[derive(Clone, Debug)]
pub struct TwitchConfig {
    pub client_id: String,
    /// Only for apps registered as "Confidential". Public apps don't have one.
    pub client_secret: Option<String>,
    /// RTMP(S) base URL; the stream key is appended.
    pub ingest_url: String,
}

/// A Google OAuth client of type "TVs and Limited Input devices". Google's
/// device flow needs the secret too (it isn't really secret for this type).
#[derive(Clone, Debug)]
pub struct YouTubeConfig {
    pub client_id: String,
    pub client_secret: String,
}

/// An RTMP source from X Media Studio › Producer › Sources.
#[derive(Clone, Debug)]
pub struct XConfig {
    pub rtmp_url: String,
    pub stream_key: String,
}

impl Config {
    pub fn from_env() -> Result<Config> {
        let var = |name: &str| env::var(name).ok().filter(|v| !v.trim().is_empty());
        let port = |name: &str, default: u16| -> Result<u16> {
            var(name).map_or(Ok(default), |v| v.parse().with_context(|| format!("{name} must be a port number")))
        };
        let twitch = var("TWITCH_CLIENT_ID").map(|client_id| TwitchConfig {
            client_id,
            client_secret: var("TWITCH_CLIENT_SECRET"),
            ingest_url: var("TWITCH_INGEST_URL")
                .unwrap_or_else(|| "rtmps://ingest.global-contribute.live-video.net:443/app".into()),
        });
        let youtube = match (var("YOUTUBE_CLIENT_ID"), var("YOUTUBE_CLIENT_SECRET")) {
            (Some(client_id), Some(client_secret)) => Some(YouTubeConfig { client_id, client_secret }),
            (None, None) => None,
            _ => anyhow::bail!("Set both YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET, or neither"),
        };
        let x = match (var("X_RTMP_URL"), var("X_STREAM_KEY")) {
            (Some(rtmp_url), Some(stream_key)) => {
                anyhow::ensure!(
                    rtmp_url.starts_with("rtmp://") || rtmp_url.starts_with("rtmps://"),
                    "X_RTMP_URL must start with rtmp:// or rtmps://"
                );
                Some(XConfig { rtmp_url: rtmp_url.trim().into(), stream_key: stream_key.trim().into() })
            }
            (None, None) => None,
            _ => anyhow::bail!("Set both X_RTMP_URL and X_STREAM_KEY, or neither"),
        };
        Ok(Config {
            addr: var("PARALLAX_ADDR")
                .unwrap_or_else(|| "127.0.0.1:8080".into())
                .parse()
                .context("PARALLAX_ADDR must look like 0.0.0.0:8080")?,
            data_dir: var("PARALLAX_DATA_DIR").unwrap_or_else(|| "data".into()).into(),
            api_token: var("PARALLAX_TOKEN"),
            public_host: var("PARALLAX_PUBLIC_HOST"),
            srt_port: port("PARALLAX_SRT_PORT", 8890)?,
            rtmp_port: port("PARALLAX_RTMP_PORT", 1935)?,
            mediamtx_api_port: port("PARALLAX_MEDIAMTX_API_PORT", 9997)?,
            mediamtx_bin: var("PARALLAX_MEDIAMTX").unwrap_or_else(|| "mediamtx".into()),
            ffmpeg_bin: var("PARALLAX_FFMPEG").unwrap_or_else(|| "ffmpeg".into()),
            twitch,
            youtube,
            x,
        })
    }
}
