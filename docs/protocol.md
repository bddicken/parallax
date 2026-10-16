# Client ↔ server protocol

Types: `server/src/protocol.rs` ⇄ `client/Sources/ParallaxRemote/Protocol.swift`. Keep them in sync: both sides' tests decode the samples in [`protocol-fixtures/`](protocol-fixtures/), so add or update a fixture when a type changes.

Every `/v1` endpoint requires `Authorization: Bearer <token>`. Bodies are JSON, times are RFC 3339 with milliseconds, and errors are plain text meant to be shown to the user.

| Method | Path | Body → Response |
|---|---|---|
| GET | `/healthz` | → `ok` (no auth) |
| GET | `/v1/status` | → `BroadcastStatus` |
| GET | `/v1/ingest` | → `IngestInfo` (`srtURL`, `rtmpURL`) |
| GET | `/v1/destinations` | → `[Destination]` (stream keys omitted). `chatURL?` is the platform's pop-out chat page: Twitch always, YouTube once a broadcast exists, X when `X_USERNAME` is set (the client also reads and sends X chat through it). |
| PUT | `/v1/destinations` | `[Destination]` → 204. Replaces the `custom` destinations; a missing `streamKey` keeps the saved one. Platform destinations come from connected accounts, or for X, the server's `.env`. |
| POST | `/v1/broadcast/start` | `{destinationIDs: [..], title?, privacy?: public\|unlisted\|private, rehearsal?}` → 204. `title` and `privacy` apply where a platform creates a video per broadcast (YouTube). With `rehearsal: true`, each destination's relay reads the ingest but discards it, and no platform is contacted (no YouTube broadcast, no stream key lookup). |
| POST | `/v1/broadcast/stop` | → 204 |
| POST | `/v1/broadcast/preview` | → 204, or 400 if not rehearsing or the server doesn't show previews. Reopens the rehearsal's preview window: what the first destination's relay sends, played by `ffplay` on the server's Mac. Only the app's built-in server shows one (`PARALLAX_PREVIEW_WINDOW`), opening it when a rehearsal starts. |
| POST | `/v1/broadcast/slate?fps=30` | JPEG or PNG bytes at the stream's size (≤ 20 MB) → 204, or 409 while live. What viewers see while the client isn't sending video (e.g. while the app restarts mid-broadcast). The server turns it into a short H.264 + AAC loop at `fps`. The client sends it before going live; until then MediaMTX's blank one plays. |
| POST | `/v1/broadcast/thumbnail` | JPEG or PNG bytes (≤ 2 MB) → 204. Sets the thumbnail of the broadcast under way, on platforms that take one (YouTube). The client sends it right after `start`, and again if you change it while live. |
| POST | `/v1/chat/send` | `{text, platforms?}` → 204 (no `platforms` means every platform with chat open; YouTube chat exists only while live there) |
| GET | `/v1/accounts` | → `[Account]` |
| POST | `/v1/accounts/{platform}/connect` | → `DeviceCode` `{userCode, verificationURL, expiresAt}`. The user opens the URL and enters the code; an `accounts` event follows when they finish. `twitch` or `youtube`. |
| DELETE | `/v1/accounts/{platform}` | → 204 |
| GET | `/v1/events` | WebSocket of `{type, data}` events. Sends the current `broadcast.status` and `accounts` on connect. |

Events:

- `chat.message` → `ChatMessage` `{id, platform, author{id, displayName, avatarURL?, isOwner, isModerator}, text, timestamp}`
- `broadcast.status` → `BroadcastStatus` `{live, ingestActive, startedAt?, destinations[{destinationID, state, bitrateKbps, error?}], rehearsal?}` (`rehearsal` is left out when false). `live` without `ingestActive` means the slate is playing; the client starts sending again when it sees that.
- `accounts` → `[Account]` `{platform, state: disconnected|pending|connected, login?, displayName?, pending?: DeviceCode, error?}`

Unknown event types must be ignored so either side can add events.

Media: the client pushes H.264 + AAC as MPEG-TS over SRT to `IngestInfo.srtURL` (the `streamid` carries the ingest key), or as FLV to `rtmpURL` as a fallback. The server relays it unchanged, so the client's encoder settings must suit every destination: Twitch needs H.264, a 2 s keyframe interval, and at most 6 Mbps; YouTube and X accept that too (X wants keyframes at most 3 s apart, up to 12 Mbps and 60 fps).
