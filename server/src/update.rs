//! Self-update, for servers installed by Parallax's DigitalOcean deploy
//! (`deploy/cloud-init.sh`): downloads a release binary built by
//! `.github/workflows/server-release.yml`, checks that it runs here, and
//! swaps it in. The caller then exits, and systemd starts the new binary.

use std::{
    path::{Path, PathBuf},
    process::Stdio,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use futures_util::StreamExt;
use tokio::{io::AsyncWriteExt, process::Command};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// A release version as it appears after `server-v` in a tag: `1.2.3`, or
/// `1.2.3-rc.1`.
pub fn is_version(v: &str) -> bool {
    let (core, pre) = match v.split_once('-') {
        Some((core, pre)) => (core, Some(pre)),
        None => (v, None),
    };
    let numbers: Vec<&str> = core.split('.').collect();
    numbers.len() == 3
        && numbers.iter().all(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
        && pre.is_none_or(|p| !p.is_empty() && p.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'))
}

/// This machine's release asset, e.g. `parallax-server-linux-amd64`.
pub fn asset_name() -> Result<String> {
    ensure!(std::env::consts::OS == "linux", "Release builds are Linux only.");
    let arch = match std::env::consts::ARCH {
        "x86_64" => "amd64",
        "aarch64" => "arm64",
        other => bail!("There are no release builds for {other}."),
    };
    Ok(format!("parallax-server-linux-{arch}"))
}

pub fn download_url(repo: &str, version: &str, asset: &str) -> String {
    format!("https://github.com/{repo}/releases/download/server-v{version}/{asset}")
}

/// Replaces the running binary with release `version` from `repo`. The
/// running process keeps its old copy until it exits.
pub async fn install(repo: &str, version: &str) -> Result<()> {
    ensure!(is_version(version), "{version:?} isn't a release version.");
    let url = download_url(repo, version, &asset_name()?);
    let exe = running_binary()?;
    let staged = exe.with_file_name(".parallax-server.new");
    let result = stage(&url, version, &staged).await;
    if result.is_ok() {
        // Same directory, so the swap is atomic.
        if let Err(e) = tokio::fs::rename(&staged, &exe).await {
            let _ = tokio::fs::remove_file(&staged).await;
            return Err(e).with_context(|| format!("replacing {}", exe.display()));
        }
    } else {
        let _ = tokio::fs::remove_file(&staged).await;
    }
    result
}

/// Where this binary lives. Linux appends " (deleted)" once the file has been
/// replaced, which happens if an update installs but the restart doesn't.
fn running_binary() -> Result<PathBuf> {
    let exe = std::env::current_exe().context("finding this binary")?;
    let path = exe.to_string_lossy();
    Ok(match path.strip_suffix(" (deleted)") {
        Some(original) => PathBuf::from(original),
        None => exe,
    })
}

/// Downloads to `path` and checks the result reports `version`, which also
/// proves it runs on this machine.
async fn stage(url: &str, version: &str, path: &Path) -> Result<()> {
    let http = reqwest::Client::builder().timeout(Duration::from_secs(300)).build()?;
    let response = http.get(url).send().await.with_context(|| format!("downloading {url}"))?;
    ensure!(response.status().is_success(), "Downloading {url} failed ({}).", response.status());
    let mut options = tokio::fs::OpenOptions::new();
    options.write(true).create(true).truncate(true);
    #[cfg(unix)]
    options.mode(0o755);
    let mut file = options.open(path).await.with_context(|| format!("writing {}", path.display()))?;
    let mut body = response.bytes_stream();
    while let Some(chunk) = body.next().await {
        file.write_all(&chunk.with_context(|| format!("downloading {url}"))?).await?;
    }
    file.sync_all().await?;
    drop(file);

    let output = tokio::time::timeout(
        Duration::from_secs(10),
        Command::new(path).arg("--version").stdin(Stdio::null()).kill_on_drop(true).output(),
    )
    .await
    .context("the new binary didn't answer --version")?
    .context("running the new binary")?;
    let reported = String::from_utf8_lossy(&output.stdout);
    ensure!(
        output.status.success() && reported.trim() == format!("parallax-server {version}"),
        "The downloaded binary doesn't report version {version} (it said {:?}).",
        reported.trim()
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_release_versions_only() {
        for good in ["0.1.0", "12.0.3", "1.2.3-rc.1", "1.2.3-beta-2"] {
            assert!(is_version(good), "{good}");
        }
        for bad in ["", "1.2", "1.2.3.4", "v1.2.3", "1.2.x", "1.2.3-", "1.2.3/../x", "1..3", "1.2.3-a b"] {
            assert!(!is_version(bad), "{bad}");
        }
    }

    #[test]
    fn builds_release_urls() {
        assert_eq!(
            download_url("bddicken/parallax", "0.2.0", "parallax-server-linux-amd64"),
            "https://github.com/bddicken/parallax/releases/download/server-v0.2.0/parallax-server-linux-amd64"
        );
    }

    /// Serves a stand-in "binary" (a script) and stages it.
    #[cfg(unix)]
    #[tokio::test]
    async fn stages_only_a_download_that_reports_the_version() {
        let app = axum::Router::new()
            .route("/bin", axum::routing::get(|| async { "#!/bin/sh\necho parallax-server 9.9.9\n" }));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/bin", listener.local_addr().unwrap());
        tokio::spawn(async move { axum::serve(listener, app).await.unwrap() });
        let dir = std::env::temp_dir().join(format!("parallax-update-test-{}", crate::store::secret(8)));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("staged");

        stage(&url, "9.9.9", &path).await.unwrap();
        let error = stage(&url, "9.9.8", &path).await.unwrap_err();
        assert!(error.to_string().contains("doesn't report version 9.9.8"), "{error:#}");
        let error = stage(&url.replace("/bin", "/missing"), "9.9.9", &path).await.unwrap_err();
        assert!(error.to_string().contains("404"), "{error:#}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn this_crate_has_a_release_version() {
        assert!(is_version(VERSION));
    }
}
