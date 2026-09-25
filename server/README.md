# parallax-server

The relay between the Parallax app and streaming platforms. The Mac uploads one stream; the server sends it on to each platform and brings their chat back.

```
Parallax ──SRT──▶ MediaMTX ──RTMP (local)──▶ ffmpeg -c copy ──RTMPS──▶ Twitch, YouTube, X
    ▲                (ingest)                  (one per destination)
    └── REST + WebSocket ──▶ parallax-server ◀── platform APIs (sign-in, stream keys, chat)
```

It leans on existing tools for media: [MediaMTX](https://mediamtx.org) receives the stream and ffmpeg relays it without re-encoding. The server runs both as child processes and restarts them if they exit. Twitch uses the [`twitch_api`](https://docs.rs/twitch_api) and [`twitch_oauth2`](https://docs.rs/twitch_oauth2) crates; YouTube uses [`oauth2`](https://docs.rs/oauth2) for sign-in and calls the YouTube Data API directly.

| File | What |
|---|---|
| `src/api.rs` | Control API ([protocol](../docs/protocol.md)): bearer auth, REST, `/v1/events` WebSocket |
| `src/protocol.rs` | Wire types, mirrored in `client/Sources/ParallaxRemote/Protocol.swift` |
| `src/ingest.rs` | Generates the MediaMTX config and runs it; tracks whether video is arriving |
| `src/broadcast.rs` | Go live / stop; runs and watches one ffmpeg per destination |
| `src/twitch.rs` | Device code sign-in, token refresh, stream key, chat (EventSub WebSocket in, Helix out) |
| `src/youtube.rs` | Device code sign-in, a reusable stream, one broadcast per go-live, chat (streamed or polled in, `liveChatMessages.insert` out) |
| `src/x.rs` | X ingest URL from `.env` (switched to RTMPS). Video only for now |
| `src/store.rs` | `data/state.json`: API token, ingest key, platform sign-ins, custom destinations |

## Run locally

```bash
brew install mediamtx ffmpeg
```

```bash
cp .env.example .env   # then fill in the platforms you use (see below)
cargo run
```

It prints the API token on startup. In Parallax, open Settings › Server, enter `http://127.0.0.1:8080` and the token, then connect Twitch and YouTube.

### Platforms

Each platform needs some one-time setup on your account. Step-by-step guides:

- [Twitch setup](../docs/setup/twitch.md): `TWITCH_CLIENT_ID` (and `TWITCH_CLIENT_SECRET` for Confidential apps)
- [YouTube setup](../docs/setup/youtube.md): `YOUTUBE_CLIENT_ID` and `YOUTUBE_CLIENT_SECRET`
- [X setup](../docs/setup/x.md): `X_RTMP_URL` and `X_STREAM_KEY` from an X Media Studio source (video only; you start and end broadcasts in Media Studio)

### Test without an account

A `custom` destination can point at any RTMP server, such as ffmpeg listening locally:

```bash
ffmpeg -listen 1 -i rtmp://127.0.0.1:19350/app/test -c copy out.flv
```

```bash
curl -X PUT localhost:8080/v1/destinations -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
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
| `YOUTUBE_CLIENT_ID` / `YOUTUBE_CLIENT_SECRET` | | Enables YouTube (both required) |
| `X_RTMP_URL` / `X_STREAM_KEY` | | Enables X: a Media Studio source's server URL and stream key (both required) |
| `X_USERNAME` | | Your X handle, so the app can open X's chat page (optional) |

`data/state.json` holds tokens, so it's written with owner-only permissions.
