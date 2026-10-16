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
| `src/store.rs` | `data/state.json`: API token, ingest key, platform sign-ins, custom destinations, the slate, and the live broadcast |

## Built into the app

Parallax runs this server itself when Settings › Server is set to **This Mac** (the default); `client/scripts/build-app.sh` bundles it into the app. It runs while the app is open, listens on localhost only with ports and a token the app picks, and keeps its state in `~/Library/Application Support/Parallax/Server/` (with `server.log`). Platform settings are entered in Settings › Server instead of `.env`. You still need `brew install mediamtx ffmpeg`.

## Restarting mid-broadcast

The app and the server can each restart without ending a broadcast:

- **The app.** While nothing's coming from the app, MediaMTX plays a slate ("We'll be right back", which the app sends before going live) on the ingest path, so relays stay connected and viewers keep watching. Quitting while live asks whether to keep the broadcast going (a `SIGTERM` or a relaunch keeps it without asking). The built-in server keeps running after the app quits while it's live, and the app saves its address in `Server/endpoint.json`. The next launch takes it over and starts sending video again. If nothing comes back for `PARALLAX_OFFLINE_TIMEOUT` (15 minutes), the server ends the broadcast, and once nothing's live and no app is connected, it exits.
- **The server.** The live broadcast is saved in `state.json`, so a restarted server starts its relays again right away (on the slate until video arrives). The app restarts its built-in server on the same ports, so the uplink reconnects by itself. Viewers see a few seconds of buffering while each relay reconnects to its platform. YouTube broadcasts are created with auto-stop off for this reason; the server ends them itself.

This needs a MediaMTX with always-available paths (`alwaysAvailable`, tested with 1.21).

## Run it yourself

For a remote host, or to work on the server:

```bash
brew install mediamtx ffmpeg
```

```bash
cp .env.example .env   # then fill in the platforms you use (see below)
cargo run
```

It prints the API token on startup. In Parallax, open Settings › Server, choose **Another machine**, enter the server's URL (`http://127.0.0.1:8080` here) and the token, then connect Twitch and YouTube.

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
| `PARALLAX_INGEST_BIND` | all interfaces | IP the ingest listens on (e.g. `127.0.0.1`) |
| `PARALLAX_SRT_PORT` / `PARALLAX_RTMP_PORT` | `8890` / `1935` | Ingest ports (SRT is UDP) |
| `PARALLAX_MEDIAMTX_API_PORT` | `9997` | MediaMTX API, localhost only |
| `PARALLAX_MEDIAMTX` / `PARALLAX_FFMPEG` | from `PATH` | Binaries |
| `PARALLAX_PREVIEW_WINDOW` | | `1` opens a window during a rehearsal showing what the first destination would get. Only for a server on the Mac you're at; the app's built-in server sets it |
| `PARALLAX_FFPLAY` | next to ffmpeg | The player for that window |
| `PARALLAX_PARENT_PID` | | The app running this server. Once it exits, the server exits too, except while a broadcast is live or another app is connected |
| `PARALLAX_OFFLINE_TIMEOUT` | `900` | Seconds without video from the app before a live broadcast ends (`0`: never) |
| `TWITCH_CLIENT_ID` | | Enables Twitch |
| `TWITCH_CLIENT_SECRET` | | Only for Confidential apps |
| `TWITCH_INGEST_URL` | `rtmps://ingest.global-contribute.live-video.net:443/app` | Twitch ingest (auto-picks the nearest region) |
| `YOUTUBE_CLIENT_ID` / `YOUTUBE_CLIENT_SECRET` | | Enables YouTube (both required) |
| `X_RTMP_URL` / `X_STREAM_KEY` | | Enables X: a Media Studio source's server URL and stream key (both required) |
| `X_USERNAME` | | Your X handle, so the app can open X's chat page (optional) |

`data/state.json` holds tokens, so it's written with owner-only permissions.
