//! Server state that survives restarts, in one JSON file. It's a single-user
//! server with a handful of settings, so a database would be overkill.

use std::{
    io::Write,
    path::{Path, PathBuf},
    sync::Mutex,
};

use anyhow::{Context, Result};
use rand::distr::{Alphanumeric, SampleString};
use serde::{Deserialize, Serialize};

use crate::protocol::Destination;

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    /// Bearer token for the control API.
    pub api_token: String,
    /// Password the client uses to publish video to MediaMTX.
    pub ingest_key: String,
    pub twitch: Option<TwitchAuth>,
    pub youtube: Option<YouTubeAuth>,
    /// The reusable YouTube stream (ingest point) we push video to.
    pub youtube_stream: Option<YouTubeStream>,
    /// The YouTube broadcast we're live on, so a restart can pick its chat back up.
    pub youtube_broadcast: Option<YouTubeBroadcast>,
    /// Destinations set up by URL and stream key: custom RTMP and LinkedIn.
    /// (The name predates LinkedIn.) Other platforms come from accounts.
    pub custom_destinations: Vec<Destination>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct TwitchAuth {
    pub access_token: String,
    pub refresh_token: Option<String>,
    pub user_id: String,
    pub login: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct YouTubeAuth {
    pub refresh_token: String,
    pub channel_id: String,
    pub title: String,
    pub handle: Option<String>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct YouTubeStream {
    pub id: String,
    /// RTMP(S) URL including the stream name (key).
    pub url: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct YouTubeBroadcast {
    pub id: String,
    pub live_chat_id: Option<String>,
}

pub struct Store {
    path: PathBuf,
    state: Mutex<State>,
}

impl Store {
    /// Loads `state.json` from `dir`, creating secrets on first run.
    pub fn open(dir: &Path) -> Result<Store> {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
        let path = dir.join("state.json");
        let mut state: State = match std::fs::read_to_string(&path) {
            Ok(s) => serde_json::from_str(&s).with_context(|| format!("reading {}", path.display()))?,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => State::default(),
            Err(e) => return Err(e).with_context(|| format!("reading {}", path.display())),
        };
        if state.api_token.is_empty() {
            state.api_token = secret(32);
        }
        if state.ingest_key.is_empty() {
            state.ingest_key = secret(24);
        }
        let store = Store { path, state: Mutex::new(state) };
        store.update(|_| ())?;
        Ok(store)
    }

    pub fn get(&self) -> State {
        self.state.lock().unwrap().clone()
    }

    /// Applies `change` and writes the file (atomically, readable only by us:
    /// it holds tokens).
    pub fn update<T>(&self, change: impl FnOnce(&mut State) -> T) -> Result<T> {
        let mut state = self.state.lock().unwrap();
        let out = change(&mut state);
        let tmp = self.path.with_extension("json.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp).with_context(|| format!("writing {}", tmp.display()))?;
        file.write_all(&serde_json::to_vec_pretty(&*state)?)?;
        file.sync_all()?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(out)
    }
}

pub fn secret(len: usize) -> String {
    Alphanumeric.sample_string(&mut rand::rng(), len)
}
