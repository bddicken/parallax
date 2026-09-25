# LinkedIn Live

Parallax streams to LinkedIn with the stream URL and key from LinkedIn Live Studio ([setup](../server/README.md#linkedin)). This page records what a full integration (sign in, go live from the app, chat) would take, so we can pick it up if we get API access. Researched September 2026.

## Access is the blocker

- The API is the **Live Events API** program, requested from an app's Products tab on developer.linkedin.com. It goes through Microsoft's OneVet verification, which asks for an organization name, address, website, and use case, and is aimed at streaming and conferencing companies. The docs don't say individuals can't apply, but related programs reject personal accounts, so plan on needing a registered company. ([Live Events](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/live-video), [program announcement](https://www.linkedin.com/developers/news/featured-updates/live-events))
- It starts at a Development tier of about 100 calls per API per day. The Standard tier needs a demo video of LinkedIn's certification test cases.
- The broadcaster needs LinkedIn Live access too: 150+ followers or connections, an account at least 30 days old, and good standing. `GET /v2/contentAccess/(entity:(member:urn:li:person:{id}),featureType:LIVE_VIDEO)` checks this (200 means yes, 404 means no). ([criteria](https://www.linkedin.com/help/linkedin/answer/a568503), [content access](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/live-video/live-video-content-access))

## Sign-in

- Standard OAuth authorization code flow, with a client secret. There's **no device code flow**, so unlike Twitch and YouTube the server would need a reachable HTTPS redirect URI. PKCE with a loopback redirect exists only for native apps, and LinkedIn has to turn it on for you. ([auth code flow](https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow), [native PKCE](https://learn.microsoft.com/en-us/linkedin/shared/authentication/authorization-code-flow-native))
- Scopes are `w_member_live` and `r_member_live` for a profile, plus `openid profile` for the member ID. A Page uses `w_organization_live`, `r_organization_live`, and `r_organization_admin` instead. Profile and Page scopes can't be requested together.
- Access tokens last 60 days. Refresh tokens (365 days) are available to Live partners on request.

## Going live

The one-step "go live now" flow was retired (June 2026). Every stream is a scheduled event; for "now", schedule it a minute ahead. ([migration guide](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/live-video/live-video-spontaneous-migration), [scheduled flow](https://learn.microsoft.com/en-us/linkedin/consumer/integrations/live-video/live-video-scheduled-live))

All calls are on `https://api.linkedin.com/v2` with `X-Restli-Protocol-Version: 2.0.0`:

1. `POST /liveVideos` `{author: {member: urn}, scheduledAt: now + 60 s, name}` returns the live video ID.
2. `POST /ugcPosts` announces it (media `urn:li:liveVideo:{id}`), which returns the post URN that comments hang off.
3. `POST /liveAssetActions?action=register` `{registerLiveEventRequest: {owner, recipes: ["urn:li:digitalmediaRecipe:feedshare-live-video"], region: "WEST_US"}}` returns `ingestUrls` (RTMP and RTMPS, primary and backup) with the key as the last path segment, plus the asset URN. This is allowed from 15 minutes before to 2 hours after the scheduled time.
4. Push video, then poll `GET /assets/{id}` until the recipe status is `AVAILABLE` (if it isn't after about 15 s, ingest failed).
5. `POST /liveVideos/{id}` `{patch: {$set: {liveVideoAsset: {media: assetUrn}}}}` links the asset to the event.
6. To stop: `POST /liveAssetActions?action=end` `{asset}`, about 10 s after the video stops.

This would slot into `start`/`stop` in `api.rs` the way `youtube.rs` does.

## Chat

LinkedIn has no live chat API. Live comments are ordinary comments on the post, readable only by polling `GET /rest/socialActions/{postUrn}/comments`. Reading them on a member's post needs `r_member_social_feed`, which LinkedIn grants to select developers only; Page posts need Community Management API access, which is for registered organizations. Posting comments has a per-member throttle of about one a minute. ([Comments API](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/shares/comments-api))

## Stream limits

H.264 + AAC, 16:9, up to 1080p and 30 fps, 2 s keyframes, video up to 6 Mbps, audio up to 128 kbps at 48 kHz, and at most 4 hours. RTMPS is preferred. Ingest drops after about 90 s without data.
