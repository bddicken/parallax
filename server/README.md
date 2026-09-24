# parallax-server

The relay between the Parallax app and streaming platforms. The Mac uploads one stream; the server sends it on to each platform and brings their chat back.

```
Parallax ──SRT──▶ MediaMTX ──RTMP (local)──▶ ffmpeg -c copy ──RTMPS──▶ Twitch
    ▲                (ingest)                  (one per destination)
    └── REST + WebSocket ──▶ parallax-server ◀── Twitch API (sign-in, stream key, chat)
```

It leans on existing tools for media: [MediaMTX](https://mediamtx.org) receives the stream and ffmpeg relays it without re-encoding. The server runs both as child processes and restarts them if they exit. Twitch sign-in and chat use the [`twitch_api`](https://docs.rs/twitch_api) and [`twitch_oauth2`](https://docs.rs/twitch_oauth2) crates.

| File | What |
|---|---|
| `src/api.rs` | Control API ([protocol](../docs/protocol.md)): bearer auth, REST, `/v1/events` WebSocket |
| `src/protocol.rs` | Wire types, mirrored in `client/Sources/ParallaxRemote/Protocol.swift` |
| `src/ingest.rs` | Generates the MediaMTX config and runs it; tracks whether video is arriving |
| `src/broadcast.rs` | Go live / stop; runs and watches one ffmpeg per destination |
| `src/twitch.rs` | Device code sign-in, token refresh, stream key, chat (EventSub WebSocket in, Helix out) |
| `src/store.rs` | `data/state.json`: API token, ingest key, Twitch tokens, custom destinations |

## Run locally

```bash
brew install mediamtx ffmpeg
```

```bash
cp .env.example .env   # then set TWITCH_CLIENT_ID
cargo run
```

It prints the API token on startup. In Parallax, open Settings › Server, enter `http://127.0.0.1:8080` and the token, then click **Connect Twitch**.

### Twitch app

Register an app at [dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps):

- **OAuth Redirect URL:** `http://localhost` (required by the form, but not used: sign-in uses the device code flow).
- **Category:** Broadcaster Suite.
- **Client Type:** Public. Then only `TWITCH_CLIENT_ID` is needed.

Scopes requested: `channel:read:stream_key`, `user:read:chat`, `user:write:chat`.

### Test without Twitch

A `custom` destination can point at any RTMP server, such as ffmpeg listening locally:

```bash
ffmpeg -listen 1 -i rtmp://127.0.0.1:19350/app/test -c copy out.flv
```

```bash
curl -X PUT localhost:8080/v1/destinations -H "Authorization: Bearer $TOKEN" \
  -d '[{"id":"local","platform":"custom","name":"Local test","enabled":true,"rtmpURL":"rtmp://127.0.0.1:19350/app","streamKey":"test"}]'
```

## Configuration

Environment variables (a `.env` file works too):

| Variable | Default | |
|---|---|---|
| `PARALLAX_ADDR` | `127.0.0.1:8080` | Control API listen address |
| `PARALLAX_DATA_DIR` | `data` | Saved state and the generated MediaMTX config |
| `PARALLAX_TOKEN` | generated | API token |
| `PARALLAX_PUBLIC_HOST` | host the client connected to | Host name given to the client for sending video |
| `PARALLAX_SRT_PORT` / `PARALLAX_RTMP_PORT` | `8890` / `1935` | Ingest ports (SRT is UDP) |
| `PARALLAX_MEDIAMTX_API_PORT` | `9997` | MediaMTX API, localhost only |
| `PARALLAX_MEDIAMTX` / `PARALLAX_FFMPEG` | from `PATH` | Binaries |
| `TWITCH_CLIENT_ID` | | Enables Twitch |
| `TWITCH_CLIENT_SECRET` | | Only for Confidential apps |
| `TWITCH_INGEST_URL` | `rtmps://ingest.global-contribute.live-video.net:443/app` | Twitch ingest (auto-picks the nearest region) |

`data/state.json` holds tokens, so it's written with owner-only permissions.
