//! Wire types shared with the client. The Swift mirror lives in
//! client/Sources/ParallaxRemote/Protocol.swift; keep the two in sync, and
//! see docs/protocol.md. Field names are the client's (camelCase, with `ID`
//! and `URL` capitalized), so most fields are renamed explicitly.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Platform {
    Youtube,
    X,
    Twitch,
    /// Any RTMP(S) target, without chat. Handy for testing.
    Custom,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Destination {
    pub id: String,
    pub platform: Platform,
    pub name: String,
    pub enabled: bool,
    /// Write-only for `custom` destinations. The server never returns stream keys.
    #[serde(rename = "rtmpURL", default, skip_serializing_if = "Option::is_none")]
    pub rtmp_url: Option<String>,
    #[serde(rename = "streamKey", default, skip_serializing_if = "Option::is_none")]
    pub stream_key: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum DestinationState {
    Idle,
    Connecting,
    Live,
    Error,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DestinationStatus {
    #[serde(rename = "destinationID")]
    pub destination_id: String,
    pub state: DestinationState,
    #[serde(rename = "bitrateKbps")]
    pub bitrate_kbps: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct BroadcastStatus {
    pub live: bool,
    #[serde(rename = "ingestActive")]
    pub ingest_active: bool,
    #[serde(rename = "startedAt", default, skip_serializing_if = "Option::is_none", with = "rfc3339_opt")]
    pub started_at: Option<DateTime<Utc>>,
    pub destinations: Vec<DestinationStatus>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChatAuthor {
    pub id: String,
    #[serde(rename = "displayName")]
    pub display_name: String,
    #[serde(rename = "avatarURL", default, skip_serializing_if = "Option::is_none")]
    pub avatar_url: Option<String>,
    #[serde(rename = "isOwner")]
    pub is_owner: bool,
    #[serde(rename = "isModerator")]
    pub is_moderator: bool,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct ChatMessage {
    pub id: String,
    pub platform: Platform,
    pub author: ChatAuthor,
    pub text: String,
    #[serde(with = "rfc3339")]
    pub timestamp: DateTime<Utc>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct SendChatRequest {
    pub text: String,
    /// Missing or empty means every connected platform that supports chat.
    #[serde(default)]
    pub platforms: Option<Vec<Platform>>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct StartBroadcastRequest {
    #[serde(rename = "destinationIDs")]
    pub destination_ids: Vec<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct IngestInfo {
    #[serde(rename = "srtURL")]
    pub srt_url: String,
    #[serde(rename = "rtmpURL")]
    pub rtmp_url: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AccountState {
    Disconnected,
    /// Waiting for the user to enter `pending.userCode` on the platform's site.
    Pending,
    Connected,
}

/// A platform sign-in held by the server.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Account {
    pub platform: Platform,
    pub state: AccountState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub login: Option<String>,
    #[serde(rename = "displayName", default, skip_serializing_if = "Option::is_none")]
    pub display_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<DeviceCode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// OAuth device code: the user opens `verificationURL` and enters `userCode`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DeviceCode {
    #[serde(rename = "userCode")]
    pub user_code: String,
    #[serde(rename = "verificationURL")]
    pub verification_url: String,
    #[serde(rename = "expiresAt", with = "rfc3339")]
    pub expires_at: DateTime<Utc>,
}

/// Pushed over `/v1/events` as `{"type": ..., "data": ...}`.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "data")]
pub enum ServerEvent {
    #[serde(rename = "chat.message")]
    Chat(ChatMessage),
    #[serde(rename = "broadcast.status")]
    Status(BroadcastStatus),
    #[serde(rename = "accounts")]
    Accounts(Vec<Account>),
}

/// RFC 3339 with milliseconds, which Foundation's ISO8601DateFormatter parses
/// (it rejects chrono's default nanoseconds).
mod rfc3339 {
    use chrono::{DateTime, SecondsFormat, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(dt: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&dt.to_rfc3339_opts(SecondsFormat::Millis, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let s = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&s).map(|dt| dt.with_timezone(&Utc)).map_err(serde::de::Error::custom)
    }
}

mod rfc3339_opt {
    use chrono::{DateTime, Utc};
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(dt: &Option<DateTime<Utc>>, s: S) -> Result<S::Ok, S::Error> {
        match dt {
            Some(dt) => super::rfc3339::serialize(dt, s),
            None => s.serialize_none(),
        }
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Option<DateTime<Utc>>, D::Error> {
        Option::<String>::deserialize(d)?
            .map(|s| DateTime::parse_from_rfc3339(&s).map(|dt| dt.with_timezone(&Utc)).map_err(serde::de::Error::custom))
            .transpose()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shared fixtures in docs/protocol-fixtures are what the Swift tests
    /// decode, so round-tripping them here keeps both sides honest.
    fn fixture(name: &str) -> serde_json::Value {
        let path = format!("{}/../docs/protocol-fixtures/{name}.json", env!("CARGO_MANIFEST_DIR"));
        serde_json::from_str(&std::fs::read_to_string(&path).expect(&path)).unwrap()
    }

    fn round_trips<T: Serialize + for<'de> Deserialize<'de>>(name: &str) {
        let json = fixture(name);
        let value: T = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(serde_json::to_value(&value).unwrap(), json, "{name}");
    }

    #[test]
    fn fixtures_round_trip() {
        round_trips::<Vec<Destination>>("destinations");
        round_trips::<IngestInfo>("ingest");
        round_trips::<Vec<Account>>("accounts");
        round_trips::<ServerEvent>("event-chat");
        round_trips::<ServerEvent>("event-status");
        round_trips::<ServerEvent>("event-accounts");
    }
}
