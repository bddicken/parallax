# Client ↔ server protocol

Types: `server/src/protocol.rs` ⇄ `client/Sources/ParallaxRemote/Protocol.swift`. Keep them in sync: both sides' tests decode the samples in [`protocol-fixtures/`](protocol-fixtures/), so add or update a fixture when a type changes.

Every `/v1` endpoint requires `Authorization: Bearer <token>`. Bodies are JSON, times are RFC 3339 with milliseconds, and errors are plain text meant to be shown to the user.

| Method | Path | Body → Response |
|---|---|---|
| GET | `/healthz` | → `ok` (no auth) |
| GET | `/v1/status` | → `BroadcastStatus` |
| GET | `/v1/ingest` | → `IngestInfo` (`srtURL`, `rtmpURL`) |
| GET | `/v1/destinations` | → `[Destination]` (stream keys omitted) |
| PUT | `/v1/destinations` | `[Destination]` → 204. Replaces the destinations set by URL and key (`custom` and `linkedin`); a missing `streamKey` keeps the saved one. `linkedin` needs a key, which is per event. Twitch and YouTube come from connected accounts. |
| POST | `/v1/broadcast/start` | `{destinationIDs: [..], title?, privacy?: public\|unlisted\|private}` → 204. `title` and `privacy` apply where a platform creates a video per broadcast (YouTube). |
| POST | `/v1/broadcast/stop` | → 204 |
| POST | `/v1/chat/send` | `{text, platforms?}` → 204 (no `platforms` means every platform with chat open; YouTube chat exists only while live there) |
| GET | `/v1/accounts` | → `[Account]` |
| POST | `/v1/accounts/{platform}/connect` | → `DeviceCode` `{userCode, verificationURL, expiresAt}`. The user opens the URL and enters the code; an `accounts` event follows when they finish. `twitch` or `youtube`. |
| DELETE | `/v1/accounts/{platform}` | → 204 |
| GET | `/v1/events` | WebSocket of `{type, data}` events. Sends the current `broadcast.status` and `accounts` on connect. |

Events:

- `chat.message` → `ChatMessage` `{id, platform, author{id, displayName, avatarURL?, isOwner, isModerator}, text, timestamp}`
- `broadcast.status` → `BroadcastStatus` `{live, ingestActive, startedAt?, destinations[{destinationID, state, bitrateKbps, error?}]}`
- `accounts` → `[Account]` `{platform, state: disconnected|pending|connected, login?, displayName?, pending?: DeviceCode, error?}`

Unknown event types must be ignored so either side can add events.

Media: the client pushes H.264 + AAC as MPEG-TS over SRT to `IngestInfo.srtURL` (the `streamid` carries the ingest key), or as FLV to `rtmpURL` as a fallback. The server relays it unchanged, so the client's encoder settings must suit every destination: Twitch needs H.264, a 2 s keyframe interval, and at most 6 Mbps; YouTube accepts that too, and LinkedIn does at up to 1080p and 30 fps.
