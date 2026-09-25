# YouTube setup

Stream to your YouTube channel from Parallax, with YouTube live chat in the app. You do this once; it takes about 10 minutes, plus up to 24 hours if your channel has never streamed before.

You'll need:

- A Google account with a YouTube channel.
- A running `parallax-server`, on your Mac or a host you control. See [server/README.md](../../server/README.md).

## 1. Turn on live streaming for your channel

1. Go to [youtube.com/features](https://www.youtube.com/features) while signed in to your channel.
2. Under **Live streaming**, turn it on. YouTube may ask you to verify your phone number.
3. The first time, YouTube can take **up to 24 hours** to enable streaming. You can do the rest of this guide in the meantime.

## 2. Create a Google Cloud project

Google only lets registered apps sign in to YouTube, so you register your own copy of Parallax. Nobody else can use it: sign-in only happens through your server.

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and sign in.
2. Open the project menu at the top, click **New Project**, name it (e.g. `Parallax`), and click **Create**. Make sure the new project is selected.
3. Go to **APIs & Services › Library**, search for **YouTube Data API v3**, open it, and click **Enable**.

## 3. Set up the consent screen

This is the page you'll see when you sign in.

1. Go to **Google Auth Platform** (search for it in the top bar) and click **Get started**.
2. Fill in **App information**: an **App name** (e.g. `Parallax`) and your email as **User support email**.
3. Under **Audience**, choose **External**. Personal Google accounts can only choose External. It doesn't make the app public: nobody can find or use it without your server. (If your channel belongs to a Google Workspace account, choose **Internal** instead and skip item 6 below.)
4. Enter your email under **Contact information**, agree to the policy, and click **Create**.
5. Go to **Data Access**, click **Add or remove scopes**, and add this scope (paste it into **Manually add scopes** if you don't see it in the list):
   ```
   https://www.googleapis.com/auth/youtube
   ```
   Click **Update**, then **Save**.
6. Go to **Audience** and choose how long sign-ins last:
   - **Recommended: click Publish app**, then **Confirm**. Google warns that the app "will be available to any user with a Google Account". That only means other people *could* sign in to their own accounts with it. They'd get no access to yours, and without your server there's nothing for them to use.
   - **Or stay in Testing:** under **Test users**, add your own Google account. Google then signs you out every 7 days, and you'll have to reconnect YouTube in Parallax each week.

You don't need to submit the app for Google's verification.

## 4. Create the OAuth client

1. Go to **Google Auth Platform › Clients** and click **Create client**.
2. For **Application type**, choose **TVs and Limited Input devices**. Parallax signs in with a code you enter on Google's site, and this is the only type that supports that.
3. Name it (e.g. `Parallax server`) and click **Create**.
4. Copy the **Client ID** and **Client secret**.

## 5. Give the server your client ID and secret

Add both to `server/.env` (or your host's environment variables):

```
YOUTUBE_CLIENT_ID=your-client-id.apps.googleusercontent.com
YOUTUBE_CLIENT_SECRET=your-client-secret
```

Restart the server. Its log should no longer say `YOUTUBE_CLIENT_ID/SECRET aren't set`.

Keep these values private. They aren't a password to your account, but anyone with them can make requests in your app's name and use up its daily API quota.

## 6. Connect YouTube in Parallax

1. In Parallax, open **Settings › Server**.
2. Enter the server's **URL** (e.g. `http://127.0.0.1:8080` when it runs on your Mac) and the **Token** the server printed when it started, then click **Save & Reconnect**.
3. Under **Accounts**, click **Connect YouTube…**. Your browser opens [google.com/device](https://www.google.com/device), and Parallax shows a code.
4. Enter the code and choose the Google account that owns your channel.
5. Google shows **"Google hasn't verified this app"**. Click **Advanced**, then **Go to Parallax (unsafe)**. This is expected for an app you registered yourself.
6. Allow access to **Manage your YouTube account**.

Settings now shows your channel's name.

## 7. Go live

1. In Parallax, click **Go Live** and check **YouTube**.
2. Enter a **Title**, and pick who can watch: **Public**, **Unlisted**, or **Private**. Parallax remembers both for next time. Use **Unlisted** for a test.
3. Click **Start Broadcast**. YouTube starts the broadcast as soon as your video arrives, usually within 10–20 seconds.
4. Click **End Broadcast** when you're done. The recording stays on your channel as usual.

Each Go Live creates a new YouTube broadcast with your title. In YouTube Studio you'll also see a stream key named **Parallax**; the server reuses it every time, so leave it in place.

YouTube chat appears in the chat panel while you're live on YouTube, and replies you type there post as your channel. (A YouTube broadcast's chat only exists while it's live.)

## Limits

Each Google Cloud project gets **10,000 YouTube API units a day**, resetting at midnight Pacific time. Parallax uses about:

- **150** per Go Live (creating and ending the broadcast)
- **50** per chat message you send
- **1** per batch of chat it reads

That's plenty for normal streaming. If you hit the limit, you'll see "The YouTube API's daily quota is used up" until it resets.

## Stream settings

Parallax's defaults (**Settings › Streaming**: 1080p, 6 Mbps, 2 s keyframes) suit YouTube, and also Twitch if you stream to both.

## Troubleshooting

| What you see | What to do |
|---|---|
| "The server isn't set up for this yet (set YOUTUBE_CLIENT_ID and YOUTUBE_CLIENT_SECRET)" | Add both to the server's environment (step 5) and restart it. |
| "…aren't a valid 'TVs and Limited Input devices' client" | Recreate the client with that application type (step 4) and update both values. |
| "Live streaming isn't enabled on this YouTube channel" | Finish step 1, and wait up to 24 hours if you just turned it on. |
| "This Google account has no YouTube channel" | You signed in with a different Google account. Connect again and pick the one that owns your channel. |
| "YouTube sign-in expired" | Click **Connect YouTube…** again. If this happens every week, your app is still in Testing (step 3, item 6). |
| The YouTube row says **Waiting for video from Parallax** | The server isn't receiving your stream. Check that the Go Live sheet says **Sending video to the server**, and that the server's SRT port (UDP 8890 by default) is reachable. |
| The YouTube row shows **Error** | Hover over it for YouTube's message. |

To disconnect, click **Disconnect** in **Settings › Server**. You can also remove Parallax's access at [myaccount.google.com/connections](https://myaccount.google.com/connections).
