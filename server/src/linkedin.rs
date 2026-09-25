//! LinkedIn Live. LinkedIn's Live Events API is only for vetted partner
//! organizations, so there's no sign-in: the user schedules an event in
//! LinkedIn Live Studio, clicks Prepare to go live › Get URL, and gives us the
//! stream URL and key, like a custom destination. Keys are per event, so a
//! new one is needed each time. LinkedIn has no live chat API (comments need
//! restricted scopes), so there's no chat.

use crate::protocol::Destination;

/// Checks a LinkedIn destination before it's saved.
pub fn prepare(d: &mut Destination) -> Result<(), String> {
    if d.stream_key.as_deref().is_none_or(|k| k.trim().is_empty()) {
        return Err(format!("{} needs the stream key from LinkedIn Live Studio › Prepare to go live.", d.name));
    }
    d.stream_key = d.stream_key.as_ref().map(|k| k.trim().to_owned());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::Platform;

    fn dest(url: &str, key: Option<&str>) -> Destination {
        Destination {
            id: "linkedin".into(),
            platform: Platform::Linkedin,
            name: "LinkedIn".into(),
            enabled: true,
            rtmp_url: Some(url.into()),
            stream_key: key.map(Into::into),
        }
    }

    #[test]
    fn requires_a_stream_key() {
        assert!(prepare(&mut dest("rtmps://example.linkedin.com:443/live", None)).is_err());
        assert!(prepare(&mut dest("rtmps://example.linkedin.com:443/live", Some(" "))).is_err());
    }

    #[test]
    fn trims_a_pasted_key() {
        let mut d = dest("rtmps://example.linkedin.com:443/live", Some(" abc\n"));
        prepare(&mut d).unwrap();
        assert_eq!(d.stream_key.as_deref(), Some("abc"));
    }
}
