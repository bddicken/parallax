# parallax-server

Cloud relay for Parallax. **Stub only** — the client is the current focus.

Responsibilities (planned):

- **Ingest** one high-quality uplink from the Mac client (SRT, RTMP fallback).
- **Relay** it without re-encoding to every enabled destination (YouTube, X, Twitch, custom RTMP).
- **Chat**: aggregate chat from each platform, push it to the client over a websocket, and post replies as the authenticated account.
- **Auth**: hold platform OAuth tokens / stream keys so they never live on the client.

```
cmd/parallax-server   entrypoint
internal/api          control plane (REST + /v1/events websocket)
internal/protocol     wire types, mirrored in client/Sources/ParallaxRemote
internal/ingest       uplink listener
internal/relay        fan-out to destinations
internal/chat         per-platform chat providers + hub
```

Run:

```bash
PARALLAX_TOKEN=dev go run ./cmd/parallax-server
```
