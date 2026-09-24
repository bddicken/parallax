# Client ↔ server protocol

Types: `server/internal/protocol/protocol.go` ⇄ `client/Sources/ParallaxRemote/Protocol.swift`. Keep them in sync.

All endpoints require `Authorization: Bearer <token>`. JSON bodies, and times are RFC 3339.

| Method | Path | Body → Response |
|---|---|---|
| GET | `/healthz` | → `ok` (no auth) |
| GET | `/v1/status` | → `BroadcastStatus` |
| GET | `/v1/ingest` | → `IngestInfo` (`srtURL`, `rtmpURL`) |
| GET | `/v1/destinations` | → `[Destination]` (stream keys omitted) |
| PUT | `/v1/destinations` | `[Destination]` → 204 |
| POST | `/v1/broadcast/start` | `{destinationIDs: [..]}` → 204 |
| POST | `/v1/broadcast/stop` | → 204 |
| POST | `/v1/chat/send` | `{text, platforms?}` → 204 (no `platforms` means all) |
| GET | `/v1/events` | websocket of `{type, data}` events |

Events:

- `chat.message` → `ChatMessage` `{id, platform, author{id, displayName, avatarURL?, isOwner, isModerator}, text, timestamp}`
- `broadcast.status` → `BroadcastStatus` `{live, ingestActive, startedAt?, destinations[{destinationID, state, bitrateKbps, error?}]}`

Unknown event types must be ignored so either side can add events.

Media: the client pushes H.264 + AAC to `IngestInfo.srtURL` (MPEG-TS over SRT, `streamid` authenticates), or to `rtmpURL` as a fallback.
