# Parallax (macOS client)

```bash
scripts/build-app.sh debug --open   # build/Parallax.app
scripts/test.sh                     # unit + recording integration tests
```

What works now:

- **Sources**: cameras, displays, individual windows, images, solid colors, chat feed overlay, featured-comment banner.
- **Scenes**: add, rename, duplicate, reorder, and switch with ⌘1–9, using a cut or fade transition. Sources are shared across scenes.
- **Layout**: drag to move, corner-drag to resize (Shift to ignore aspect ratio), snapping, presets (fullscreen, halves, PiP corners), fit/fill/stretch, and crop.
- **Audio**: any mic or interface (pick mono or stereo channels) plus system audio. Each input has a gain fader, mute, meter, sync delay (0–2 s), 80 Hz high-pass, and noise gate. The master bus has a limiter.
- **Video delay** per source, 0–2 s.
- **Local recording**: H.264/HEVC + AAC to .mov/.mp4, with configurable bitrate and folder. Files are fragmented, so a crash keeps what was recorded, and quitting finishes the file.
- **Output**: 720p/1080p/1440p at 30/60 fps.
- **Chat and Go Live** run against `MockBroadcastService` until `parallax-server` exists. Set a server URL in Settings to use the real HTTP client.

Settings are saved to `~/Library/Application Support/Parallax/profile.json`.

## Permissions and signing

macOS asks for Camera, Microphone, and Screen Recording access the first time each is used. With ad-hoc signing (the default), the signature changes on every build, so macOS may ask again. To avoid that, sign with a stable identity:

```bash
PARALLAX_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" scripts/build-app.sh
```

## Command Line Tools only (no Xcode)

`scripts/env.sh` builds against the macOS 26 SDK, because the 27 SDK's SwiftUI `@State` macro needs a plugin that ships only with Xcode. It also points `swift test` at the swift-testing macro plugin. With Xcode installed, neither workaround applies.
