# Twitch setup

Stream to your Twitch channel from Parallax, with Twitch chat in the app. You do this once; it takes about 5 minutes.

You'll need:

- A Twitch account with **two-factor authentication** turned on (Twitch requires it to register an app). Turn it on at [twitch.tv/settings/security](https://www.twitch.tv/settings/security).
- A running `parallax-server`, on your Mac or a host you control. See [server/README.md](../../server/README.md).

## 1. Register a Twitch app

Twitch only lets registered apps sign in, so you register your own copy of Parallax. Nobody else can use it: sign-in only happens through your server.

1. Go to [dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps) and log in.
2. Click **Register Your Application**.
3. Fill in the form:
   - **Name:** anything unique, e.g. `Parallax (yourname)`.
   - **OAuth Redirect URLs:** `http://localhost`. The form requires one, but Parallax never uses it (it signs in with a code instead of a redirect), so this works no matter where your server runs.
   - **Category:** Broadcaster Suite.
   - **Client Type:** **Public**.
4. Click **Create**, then **Manage** next to your new app.
5. Copy the **Client ID**.

If you chose **Confidential** instead, click **New Secret** and copy the secret too. The server needs it to keep you signed in; without it your sign-in stops working after about four hours.

## 2. Give the server your Client ID

Add it to `server/.env` (or your host's environment variables):

```
TWITCH_CLIENT_ID=your-client-id
```

For a Confidential app, also add:

```
TWITCH_CLIENT_SECRET=your-client-secret
```

Restart the server. Its log should no longer say `TWITCH_CLIENT_ID isn't set`.

Keep these values private. They aren't a password to your account, but anyone with them can make sign-in requests in your app's name.

## 3. Connect Twitch in Parallax

1. In Parallax, open **Settings › Server**.
2. Enter the server's **URL** (e.g. `http://127.0.0.1:8080` when it runs on your Mac) and the **Token** the server printed when it started, then click **Save & Reconnect**.
3. Under **Accounts**, click **Connect Twitch…**. Your browser opens Twitch's activation page, and Parallax shows a code.
4. On Twitch, check that the code matches, then click **Activate** and **Authorize**.

Settings now shows your Twitch name. Parallax asks for permission to:

- **Read your stream key** (`channel:read:stream_key`), so you never have to copy it.
- **Read chat** (`user:read:chat`) and **send chat as you** (`user:write:chat`).

## 4. Go live

1. Set your stream's title and category on Twitch as usual (in the [Stream Manager](https://dashboard.twitch.tv/stream-manager) or your dashboard). Parallax doesn't change them.
2. In Parallax, click **Go Live**, check **Twitch**, and click **Start Broadcast**.
3. The Twitch row turns **Live** once video reaches Twitch, usually within a few seconds.
4. Click **End Broadcast** when you're done.

Twitch chat appears in the chat panel, and replies you type there post as you. Chat works whenever you're connected, not only while live.

## Stream settings

Twitch requires H.264, a keyframe every 2 seconds, and at most 6 Mbps of video. Parallax's defaults (**Settings › Streaming**: 1080p, 6 Mbps, 2 s keyframes) meet all three. If you raise the bitrate or change the keyframe interval, Settings shows a warning.

## Troubleshooting

| What you see | What to do |
|---|---|
| "The server isn't set up for this yet (set TWITCH_CLIENT_ID)" | Add `TWITCH_CLIENT_ID` to the server's environment and restart it. |
| "Your Twitch app is Confidential, so the server needs its secret" | Add `TWITCH_CLIENT_SECRET` (step 2), restart the server, and connect again if asked. |
| "Twitch sign-in expired" | Click **Connect Twitch…** again. This happens if you haven't used Parallax for about 30 days, or you revoked access at [twitch.tv/settings/connections](https://www.twitch.tv/settings/connections). |
| The Twitch row says **Waiting for video from Parallax** | The server isn't receiving your stream. Check that the Go Live sheet says **Sending video to the server**, and that the server's SRT port (UDP 8890 by default) is reachable. |
| The Twitch row shows **Error** | Hover over it for Twitch's message. |

To disconnect, click **Disconnect** in **Settings › Server**. You can also remove Parallax's access at [twitch.tv/settings/connections](https://www.twitch.tv/settings/connections).
