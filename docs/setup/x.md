# X setup

One-time setup, about 5 minutes. You need a running [`parallax-server`](../../server/README.md) and an X account that can go live (X Premium).

X's API is approval-only, so Parallax sends video to a Media Studio source, and you start and end each broadcast in Media Studio. Parallax reads X chat from X's own chat page (see [Chat](#chat)).

## 1. Create a source

1. Go to [studio.x.com](https://studio.x.com) › **Producer** › **Sources** and click **Create Source**. (Live Studio, Producer's replacement, works the same way.)
2. Keep **RTMP**, pick the region nearest the server, and click **Create**.
3. Copy the **server URL** and the **stream key**.

## 2. Configure the server

Add to `server/.env` (or your host's environment) and restart the server:

```
X_RTMP_URL=rtmps://va.pscp.tv:443/x
X_STREAM_KEY=your-stream-key
X_USERNAME=your-handle
```

Use your source's URL; the region prefix varies. A plain `rtmp://` URL is switched to RTMPS. `X_USERNAME` is optional; Parallax needs it to find your chat at `x.com/your-handle/livechat`.

## 3. Go live

1. In Parallax, click **Go Live**, check **X**, and click **Start Broadcast**.
2. In Media Studio › **Producer** › **Broadcasts**, click **Create Broadcast**, pick your source, wait for the preview, and click **Go Live**.

To finish, click **End Broadcast** in Media Studio, then **Stop** in Parallax.

The default stream settings (1080p, 6 Mbps, 2 s keyframes) meet X's limits.

## Troubleshooting

| Problem | Fix |
|---|---|
| X isn't in the Go Live list | Set both variables and restart the server. |
| No preview in Media Studio | The broadcast must use the source whose key is in `X_STREAM_KEY`. |
| **Error** on the X row | Hover over it for the reason, usually a wrong URL or key. |
| **Waiting for video from Parallax** | The server isn't receiving video. Make sure its SRT port (UDP 8890) is reachable. |

## Chat

In the Chat panel, click the pop-out button › **Read X Chat in Parallax…**. A window opens with X's chat page. Sign in to X there the first time; Parallax remembers it. X comments then show up in the Chat panel along with Twitch and YouTube, and you can put them on stream the same way.

- You can close the window. Parallax keeps reading chat until you quit.
- Open it before or after you go live. Until your broadcast starts, the window says "Waiting for the broadcast" and checks every 30 seconds.
- Replies from Parallax's chat box go to X too (pick **X** or **All** next to the box). Parallax types them into the X Chat window and clicks Send, so they post as you.
- This depends on how X's page is built, so it can break when X changes it.
