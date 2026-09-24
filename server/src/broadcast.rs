//! Going live: one ffmpeg per destination copies the ingest stream (no
//! re-encoding) to the platform, restarting on its own if it drops.

use std::{collections::VecDeque, process::Stdio, sync::Arc, time::Duration};

use chrono::{DateTime, Utc};
use tokio::{
    io::{AsyncBufReadExt, BufReader},
    process::Command,
    sync::Mutex,
    task::JoinHandle,
    time::Instant,
};

use crate::{
    events::Events,
    ingest::Ingest,
    protocol::{BroadcastStatus, DestinationState, DestinationStatus},
};

/// A destination resolved to the URL ffmpeg pushes to.
pub struct Target {
    pub id: String,
    pub url: Result<String, String>,
}

pub struct Broadcaster {
    ffmpeg: String,
    ingest: Arc<Ingest>,
    events: Events,
    inner: Mutex<Inner>,
}

#[derive(Default)]
struct Inner {
    started_at: Option<DateTime<Utc>>,
    /// Bumped on every start and stop, so late updates from a stopped relay are dropped.
    generation: u64,
    relays: Vec<(DestinationStatus, Option<JoinHandle<()>>)>,
}

impl Broadcaster {
    pub fn new(ffmpeg: String, ingest: Arc<Ingest>, events: Events) -> Arc<Broadcaster> {
        let b = Arc::new(Broadcaster { ffmpeg, ingest, events, inner: Mutex::default() });
        // Re-announce status whenever the client starts or stops sending.
        let this = b.clone();
        tokio::spawn(async move {
            let mut ready = this.ingest.ready();
            while ready.changed().await.is_ok() {
                this.publish().await;
            }
        });
        b
    }

    pub async fn status(&self) -> BroadcastStatus {
        let inner = self.inner.lock().await;
        BroadcastStatus {
            live: inner.started_at.is_some(),
            ingest_active: *self.ingest.ready().borrow(),
            started_at: inner.started_at,
            destinations: inner.relays.iter().map(|(s, _)| s.clone()).collect(),
        }
    }

    async fn publish(&self) {
        self.events.status(self.status().await);
    }

    pub async fn start(self: &Arc<Self>, targets: Vec<Target>) {
        let mut inner = self.inner.lock().await;
        stop_relays(&mut inner);
        inner.generation += 1;
        inner.started_at = Some(Utc::now());
        let generation = inner.generation;
        for target in targets {
            let (status, task) = match target.url {
                Ok(url) => {
                    let this = self.clone();
                    let id = target.id.clone();
                    let task = tokio::spawn(async move { this.relay(generation, id, url).await });
                    (connecting(&target.id, None), Some(task))
                }
                Err(error) => (DestinationStatus { state: DestinationState::Error, ..connecting(&target.id, Some(error)) }, None),
            };
            inner.relays.push((status, task));
        }
        drop(inner);
        self.publish().await;
    }

    pub async fn stop(&self) {
        let mut inner = self.inner.lock().await;
        stop_relays(&mut inner);
        inner.generation += 1;
        inner.started_at = None;
        drop(inner);
        self.publish().await;
    }

    async fn set(&self, generation: u64, status: DestinationStatus) {
        let mut inner = self.inner.lock().await;
        if inner.generation != generation {
            return;
        }
        let Some(slot) = inner.relays.iter_mut().find(|(s, _)| s.destination_id == status.destination_id) else {
            return;
        };
        if slot.0 == status {
            return;
        }
        slot.0 = status;
        drop(inner);
        self.publish().await;
    }

    /// Keeps one destination fed until the broadcast stops (the task is aborted,
    /// which kills ffmpeg).
    async fn relay(&self, generation: u64, id: String, url: String) {
        let mut ready = self.ingest.ready();
        let mut backoff = Duration::from_secs(2);
        loop {
            if !*ready.borrow() {
                self.set(generation, connecting(&id, Some("Waiting for video from Parallax".into()))).await;
                if ready.wait_for(|r| *r).await.is_err() {
                    return;
                }
            }
            self.set(generation, connecting(&id, None)).await;
            let started = Instant::now();
            let error = self.run_ffmpeg(generation, &id, &url).await;
            tracing::warn!("relay to {id} stopped: {error}");
            if started.elapsed() > Duration::from_secs(60) {
                backoff = Duration::from_secs(2);
            }
            // The client stopping is expected; anything else is worth showing.
            if *ready.borrow() {
                let status = DestinationStatus { state: DestinationState::Error, ..connecting(&id, Some(error)) };
                self.set(generation, status).await;
                tokio::time::sleep(backoff).await;
                backoff = (backoff * 2).min(Duration::from_secs(30));
            }
        }
    }

    /// Runs one ffmpeg until it exits, reporting bitrate. Returns why it stopped.
    async fn run_ffmpeg(&self, generation: u64, id: &str, url: &str) -> String {
        let mut child = match Command::new(&self.ffmpeg)
            .args(["-hide_banner", "-nostdin", "-loglevel", "error", "-progress", "pipe:1", "-stats_period", "2"])
            .args(["-rw_timeout", "10000000", "-i", &self.ingest.local_read_url()])
            .args(["-c", "copy", "-f", "flv", "-flvflags", "no_duration_filesize", url])
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .spawn()
        {
            Ok(child) => child,
            Err(e) => return format!("Couldn't start {}: {e}", self.ffmpeg),
        };
        tracing::info!("relaying to {id} ({})", redact(url));

        // Keep the last few error lines; ffmpeg's final one is usually the reason.
        let stderr = child.stderr.take().expect("piped");
        let errors = tokio::spawn(async move {
            let mut lines = BufReader::new(stderr).lines();
            let mut last = VecDeque::new();
            while let Ok(Some(line)) = lines.next_line().await {
                if last.len() == 3 {
                    last.pop_front();
                }
                last.push_back(line);
            }
            last.into_iter().collect::<Vec<_>>().join(" ")
        });

        // `-progress` prints key=value blocks, each ending in `progress=...`.
        let mut lines = BufReader::new(child.stdout.take().expect("piped")).lines();
        let mut kbps = 0;
        while let Ok(Some(line)) = lines.next_line().await {
            if let Some(rate) = line.strip_prefix("bitrate=") {
                kbps = rate.trim_end_matches("kbits/s").trim().parse::<f64>().map_or(0, |r| r.round() as i64);
            } else if line.starts_with("progress=") {
                let status = DestinationStatus {
                    destination_id: id.into(),
                    state: DestinationState::Live,
                    bitrate_kbps: kbps,
                    error: None,
                };
                self.set(generation, status).await;
            }
        }
        let exit = child.wait().await;
        let stderr = errors.await.unwrap_or_default().replace(url, &redact(url));
        match (exit, stderr.is_empty()) {
            (_, false) => stderr,
            (Ok(status), true) => format!("ffmpeg exited ({status})"),
            (Err(e), true) => e.to_string(),
        }
    }
}

fn stop_relays(inner: &mut Inner) {
    for (_, task) in inner.relays.drain(..) {
        if let Some(task) = task {
            task.abort();
        }
    }
}

fn connecting(id: &str, error: Option<String>) -> DestinationStatus {
    DestinationStatus { destination_id: id.into(), state: DestinationState::Connecting, bitrate_kbps: 0, error }
}

/// Hides the stream key (the last path segment) in logs and errors.
fn redact(url: &str) -> String {
    match url.rsplit_once('/') {
        Some((base, _)) => format!("{base}/…"),
        None => "…".into(),
    }
}
