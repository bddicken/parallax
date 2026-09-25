# parallax-server

The relay between the Parallax app and streaming platforms. The Mac uploads one stream; the server sends it on to each platform and brings their chat back.

```
Parallax ──SRT──▶ MediaMTX ──RTMP (local)──▶ ffmpeg -c copy ──RTMPS──▶ Twitch, YouTube, LinkedIn
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
| `src/linkedin.rs` | Checks LinkedIn destinations (URL and key from Live Studio). Video only |
| `src/store.rs` | `data/state.json`: API token, ingest key, Twitch tokens, custom and LinkedIn destinations |

## Run locally

```bash
brew install mediamtx ffmpeg
```

```bash
cp .env.example .env   # then set TWITCH_CLIENT_ID
cargo run
```

It prints the API token on startup. In Parallax, open Settings › Server, enter `http://127.0.0.1:8080` and the token, then connect Twitch and YouTube.

### Twitch app

Register an app at [dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps):

- **OAuth Redirect URL:** `http://localhost` (required by the form, but not used: sign-in uses the device code flow).
- **Category:** Broadcaster Suite.
- **Client Type:** Public, so only `TWITCH_CLIENT_ID` is needed. If the app is Confidential, also set `TWITCH_CLIENT_SECRET` (sign-ins can't refresh without it).

Scopes requested: `channel:read:stream_key`, `user:read:chat`, `user:write:chat`.

### YouTube app

In the [Google Cloud console](https://console.cloud.google.com):

1. Create a project, then under **APIs & Services › Library**, enable **YouTube Data API v3**.
2. Under **Google Auth Platform**, set up the consent screen: audience **External**, and under **Data Access** add the scope `https://www.googleapis.com/auth/youtube`.
3. Under **Audience**, click **Publish app**. Apps left in "Testing" have sign-ins that expire after 7 days. You don't need Google's verification for your own use: when signing in, click **Advanced › Go to (app name)** past the "Google hasn't verified this app" screen.
4. Under **Clients**, create an OAuth client of type **TVs and Limited Input devices**, and put its ID and secret in `.env` as `YOUTUBE_CLIENT_ID` and `YOUTUBE_CLIENT_SECRET`.

The channel also needs live streaming turned on at [youtube.com/features](https://www.youtube.com/features) (it can take up to 24 hours the first time).

How it works: the server creates one reusable stream ("Parallax" in YouTube Studio) and, on each Go Live, a broadcast with the title and visibility from the app, set to start and stop with the video. Chat follows that broadcast. The API allows 10,000 quota units a day: going live costs about 150, each chat message sent 50, and each chat read 1.

### LinkedIn

LinkedIn's Live API is only for approved partner organizations (see [docs/linkedin.md](../docs/linkedin.md)), so there's no sign-in. Instead, the server pushes to the stream URL and key from LinkedIn Live Studio. Your profile or Page needs [LinkedIn Live access](https://www.linkedin.com/help/linkedin/answer/a568503).

1. Schedule a live event on LinkedIn. Within an hour of its start (two for verified Pages), go to **Live Studio › Manage streams**, pick the event, choose **Prepare to go live**, pick the region nearest the server, and click **Get URL**.
2. In Parallax › Settings › Server › LinkedIn, paste the stream URL and key and click **Save**. Or with curl:

   ```bash
   curl -X PUT localhost:8080/v1/destinations -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
     -d '[{"id":"linkedin","platform":"linkedin","name":"LinkedIn","enabled":true,"rtmpURL":"rtmps://…","streamKey":"…"}]'
   ```

3. Go live from Parallax with LinkedIn checked. When the preview shows up in Live Studio, click **Go live** there, and **End stream** when you're done.

Each event gets its own key, so paste a new one for each event. LinkedIn takes up to 1080p, 30 fps, 6 Mbps video, and 128 kbps audio, with 2 s keyframes and a 4-hour limit. `PUT /v1/destinations` replaces the whole list, so include any custom destinations you want to keep. LinkedIn chat isn't supported: live comments are only readable through restricted APIs.

### Test without Twitch or YouTube

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
| `YOUTUBE_CLIENT_ID` / `YOUTUBE_CLIENT_SECRET` | | Enables YouTube (both required) |

`data/state.json` holds tokens, so it's written with owner-only permissions.
