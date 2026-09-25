# X setup

One-time setup, about 5 minutes. You need a running [`parallax-server`](../../server/README.md) and an X account that can go live (X Premium).

X's Livestream API is approval-only, so Parallax can't sign in to X yet. Instead, the server sends video to an RTMP source you create in X's Media Studio, and you start and end each broadcast there. X chat isn't supported yet.

## 1. Create a source

1. Go to [studio.x.com](https://studio.x.com) › **Producer** › **Sources** and click **Create Source**.
2. Name it (e.g. `Parallax`), keep **RTMP**, pick the region nearest the server, and click **Create**.
3. Copy the source's **server URL** (e.g. `rtmps://va.pscp.tv:443/x`) and **stream key**. Keep them separate.

X is replacing Producer with **Live Studio**. A source from Live Studio works the same way: copy its server URL and stream key.

## 2. Configure the server

Add to `server/.env` (or your host's environment) and restart the server:

```
X_RTMP_URL=rtmps://va.pscp.tv:443/x
X_STREAM_KEY=your-stream-key
```

Use the URL exactly as Media Studio shows it (the region prefix varies). The plain `rtmp://….pscp.tv:80/x` URL works too; the server switches it to RTMPS so the key isn't sent in the clear.

## 3. Go live

1. In Parallax, click **Go Live**, check **X**, and click **Start Broadcast**.
2. In Media Studio › **Producer** › **Broadcasts**, click **Create Broadcast**, pick your source, and wait for the preview.
3. Click **Go Live**. The stream is public on your profile from here.

To finish, click **End Broadcast** in Media Studio, then **Stop** in Parallax.

The default stream settings (1080p, 6 Mbps, 2 s keyframes) meet X's limits (keyframes at most 3 s apart, up to 12 Mbps).

## Troubleshooting

| Problem | Fix |
|---|---|
| X isn't in the Go Live list | Set both `X_RTMP_URL` and `X_STREAM_KEY` and restart the server. It won't start with only one. |
| No preview in Media Studio | Check that the broadcast uses the source whose key is in `X_STREAM_KEY`. That source should show as receiving while Parallax is live. |
| **Error** on the X row | Hover over it for the reason. A wrong URL or key makes X close the connection. |
| **Waiting for video from Parallax** | The server isn't receiving video. Make sure its SRT port (UDP 8890) is reachable. |
