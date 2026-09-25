# YouTube setup

One-time setup, about 10 minutes. You need a running [`parallax-server`](../../server/README.md) and a Google account with a YouTube channel.

## 1. Enable live streaming

Turn on **Live streaming** at [youtube.com/features](https://www.youtube.com/features). The first time, it can take up to 24 hours to activate.

## 2. Create a Google Cloud project

1. At [console.cloud.google.com](https://console.cloud.google.com), create a project and select it.
2. In **APIs & Services › Library**, enable **YouTube Data API v3**.

## 3. Set up the consent screen

1. Open **Google Auth Platform** and click **Get started**.
2. Enter an app name and your email, choose audience **External** (**Internal** if your channel is on Google Workspace), and click **Create**.
3. In **Data Access**, add the scope `https://www.googleapis.com/auth/youtube` and save.
4. In **Audience**, click **Publish app**. Otherwise Google signs you out every 7 days. Publishing doesn't give anyone access to your account or server. (Workspace/Internal apps skip this.)

You don't need Google's verification.

## 4. Create the OAuth client

In **Clients**, click **Create client**, choose **TVs and Limited Input devices**, and copy the **Client ID** and **Client secret**.

## 5. Configure the server

In Parallax, open **Settings › Server**, paste them into **YouTube client ID** and **YouTube client secret**, and click **Save & Restart Server**.

Running the server yourself (**Another machine**)? Add to `server/.env` (or your host's environment) and restart it instead:

```
YOUTUBE_CLIENT_ID=your-client-id.apps.googleusercontent.com
YOUTUBE_CLIENT_SECRET=your-client-secret
```

## 6. Connect in Parallax

1. With your own server, first enter its URL and the token it printed at startup in **Settings › Server**, then click **Save & Reconnect**.
2. In **Settings › Server**, click **Connect YouTube…**, enter the code at google.com/device, and pick your channel's account.
3. At "Google hasn't verified this app", click **Advanced › Go to (app name)**, then **Allow**.

## 7. Go live

Click **Go Live**, check **YouTube**, enter a title, pick Public, Unlisted, or Private, and click **Start Broadcast**. Each Go Live creates a new YouTube broadcast; the stream key named **Parallax** in YouTube Studio is reused, so leave it there.

Chat shows in the chat panel while you're live on YouTube, and your replies post as your channel.

## Quota

Google allows 10,000 API units a day per project. Going live costs about 150, each chat message you send 50, and each chat read 1.

## Troubleshooting

| Message | Fix |
|---|---|
| "set YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET" | Step 5. |
| "…aren't a valid 'TVs and Limited Input devices' client" | Recreate the client with that type (step 4). |
| "Live streaming isn't enabled on this YouTube channel" | Step 1, then wait up to 24 hours. |
| "This Google account has no YouTube channel" | Connect again with the account that owns the channel. |
| "YouTube sign-in expired" | Connect again. If it happens weekly, publish the app (step 3). |
| "daily quota is used up" | Wait until midnight Pacific time. |
| **Waiting for video from Parallax** | The server isn't receiving video. Make sure its SRT port (UDP 8890) is reachable. |
