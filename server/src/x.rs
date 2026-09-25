//! X (Twitter) live video. X's Livestream API is approval-only, so there's no
//! sign-in: the user creates an RTMP source in Media Studio Producer
//! (studio.x.com › Producer › Sources) and puts its URL and stream key in
//! `.env`. Reading and sending chat comes later; until then the client can
//! open X's own chat page.

use crate::config::XConfig;

/// Where to push: the source's URL plus its stream key. Media Studio also
/// offers plain RTMP on port 80; we switch its hosts to RTMPS so the key isn't
/// sent in the clear.
pub fn ingest_url(config: &XConfig) -> String {
    format!("{}/{}", secure(&config.rtmp_url).trim_end_matches('/'), config.stream_key)
}

/// The account's pop-out chat page, if the server knows its handle.
pub fn chat_url(config: &XConfig) -> Option<String> {
    config.username.as_ref().map(|u| format!("https://x.com/{u}/livechat"))
}

/// `rtmp://va.pscp.tv:80/x` → `rtmps://va.pscp.tv:443/x`. Other URLs are left alone.
fn secure(url: &str) -> String {
    let Some(rest) = url.strip_prefix("rtmp://") else { return url.into() };
    let (authority, path) = rest.split_once('/').unwrap_or((rest, ""));
    let host = authority.split_once(':').map_or(authority, |(h, _)| h);
    if host.ends_with(".pscp.tv") { format!("rtmps://{host}:443/{path}") } else { url.into() }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn appends_the_key_over_rtmps() {
        let config = |url: &str| XConfig { rtmp_url: url.into(), stream_key: "abc".into(), username: None };
        assert_eq!(ingest_url(&config("rtmps://va.pscp.tv:443/x")), "rtmps://va.pscp.tv:443/x/abc");
        assert_eq!(ingest_url(&config("rtmp://va.pscp.tv:80/x/")), "rtmps://va.pscp.tv:443/x/abc");
        assert_eq!(ingest_url(&config("rtmp://ca.pscp.tv/x")), "rtmps://ca.pscp.tv:443/x/abc");
        assert_eq!(ingest_url(&config("rtmp://127.0.0.1:1935/x")), "rtmp://127.0.0.1:1935/x/abc");
    }

    #[test]
    fn links_chat_when_the_handle_is_known() {
        let mut config = XConfig { rtmp_url: String::new(), stream_key: String::new(), username: None };
        assert_eq!(chat_url(&config), None);
        config.username = Some("parallaxdev".into());
        assert_eq!(chat_url(&config).as_deref(), Some("https://x.com/parallaxdev/livechat"));
    }
}
