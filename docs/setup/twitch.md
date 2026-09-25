# Twitch setup

One-time setup, about 5 minutes. You need a running [`parallax-server`](../../server/README.md) and a Twitch account with [two-factor authentication](https://www.twitch.tv/settings/security) on (Twitch requires it to register apps).

## 1. Register a Twitch app

1. Go to [dev.twitch.tv/console/apps](https://dev.twitch.tv/console/apps) and click **Register Your Application**.
2. Fill in:
   - **Name:** anything unique, e.g. `Parallax (yourname)`
   - **OAuth Redirect URLs:** `http://localhost` (required by the form, never used)
   - **Category:** Broadcaster Suite
   - **Client Type:** Public
3. Click **Create**, then **Manage**, and copy the **Client ID**.

## 2. Configure the server

In Parallax, open **Settings › Server**, paste it into **Twitch client ID**, and click **Save & Restart Server**.

If you chose **Confidential**, also click **New Secret** and paste it into **Twitch client secret**. Without it, sign-in expires after a few hours.

Running the server yourself (**Another machine**)? Add to `server/.env` (or your host's environment) and restart it instead:

```
TWITCH_CLIENT_ID=your-client-id
```

plus `TWITCH_CLIENT_SECRET` for Confidential apps.

## 3. Connect in Parallax

1. With your own server, first enter its URL and the token it printed at startup in **Settings › Server**, then click **Save & Reconnect**.
2. In **Settings › Server**, click **Connect Twitch…**, check the code matches, and click **Activate**, then **Authorize**.

## 4. Go live

Set your title and category on Twitch as usual. In Parallax, click **Go Live**, check **Twitch**, and click **Start Broadcast**. Chat shows in the chat panel, and your replies post as you.

The default stream settings (1080p, 6 Mbps, 2 s keyframes) meet Twitch's limits.

## Troubleshooting

| Message | Fix |
|---|---|
| "set TWITCH_CLIENT_ID" | Step 2. |
| "Your Twitch app is Confidential…" | Add `TWITCH_CLIENT_SECRET` and restart the server. |
| "Twitch sign-in expired" | Connect again. |
| **Waiting for video from Parallax** | The server isn't receiving video. Make sure its SRT port (UDP 8890) is reachable. |
| **Error** on the Twitch row | Hover over it for Twitch's message. |
