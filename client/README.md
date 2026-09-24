# Parallax (macOS client)

```bash
scripts/build-app.sh debug --open   # build/Parallax.app
scripts/test.sh                     # unit + recording integration tests
```

What works now:

- **Sources**: cameras, displays, individual windows, images, solid colors, chat feed overlay, featured-comment banner.
- **Scenes**: add blank or from a layout (Camera, Screen, Screen + Camera in any corner, Side by Side). Remove with −, rename by double-clicking, duplicate, drag to reorder, and switch with ⌘1–9 using a cut or fade. Sources are shared across scenes.
- **Layout editing** in the preview:
  - Click or drag any source. Drag a corner handle to resize (aspect kept; Shift for free resize).
  - Edges snap to the canvas, safe margins, and other sources (⌘ disables snapping). Arrow keys nudge (Shift for bigger steps). Delete removes. Right-click for presets and layer order.
  - Inspector: preset buttons, a size slider that keeps corner PiPs anchored, fit/fill/stretch, rounded corners (up to circle/pill), border, drop shadow (distance, direction, blur, opacity, color), and crop. Crop trims edges in place: the rest of the image doesn't move or zoom, and the box shrinks to match. The ⇄ button swaps which camera, display, or window a layer shows.
  - Every edit is undoable (⌘Z). A whole drag is one undo step.
- **Layers**: the sources list shows the top layer first. Drag to reorder, + / − to add or remove, and the eye button hides a layer.
- **Audio**: any mic or interface (pick mono or stereo channels) plus system audio. Each input has a gain fader and, right under it, a live sync delay slider (0–1000 ms), plus mute, meter, 80 Hz high-pass, and noise gate. The master bus has a limiter.
- **Audio monitor**: the headphones button next to Cut/Fade picks where you hear the program mix (None, System Default, or any connected output) and sets its volume. It follows device plug/unplug and system default changes.
- **Video delay** per source, 0–2 s.
- **Local recording**: H.264/HEVC + AAC to .mov/.mp4, with configurable bitrate and folder. Files are fragmented, so a crash keeps what was recorded, and quitting finishes the file.
- **Canvas**: 720p, 1080p, 1440p, or 4K at 30/60 fps, shown on the preview (click it to change). **Recording** and **streaming** each have their own resolution (canvas size or scaled down), bitrate with a recommended value, and a size and bitrate summary, so you can record in 4K and stream in 1080p.
- **Go Live and chat** use [`parallax-server`](../server/). In Settings › Server, enter its URL and token, then **Connect Twitch** (you approve Parallax on twitch.tv; no stream key to copy). **Go Live** encodes the program once (H.264 + AAC via [HaishinKit](https://github.com/HaishinKit/HaishinKit.swift)) and sends it to the server over SRT, reconnecting by itself if the connection drops; the server relays it to Twitch. Twitch chat shows up in the chat panel, and replies post as you. Without a server, the **Mock** toggle in the chat header fills chat with fake messages; it is off by default.

Sources survive restarts and replugging. Displays are remembered by hardware UUID, cameras and mics by device ID with name and model as a fallback, and windows by app and title. A missing device shows a ⚠︎ "waiting…" on its source and reconnects by itself when it's back.

Settings are saved to `~/Library/Application Support/Parallax/profile.json`. Set `PARALLAX_PROFILE=/some/path.json` to try things without touching it.

## Permissions and signing

Parallax asks for Camera, Microphone, or Screen Recording access only when a source needs it and access isn't already granted. If access is off, it shows a sheet that opens the right System Settings pane. After **Not Now**, it won't ask again until you click the source's ⚠︎ icon.

macOS ties those grants to the app's code signature. A plain ad-hoc signature is tied to the exact binary, so every rebuild would look like a new app. `build-app.sh` pins the signature's designated requirement to the bundle ID (`identifier "com.bddicken.parallax"`) instead, so grants survive rebuilds without any certificate.

To use a real identity (for example, for distribution), run `scripts/setup-signing.sh` once to create a trusted local certificate, or set `PARALLAX_SIGN_IDENTITY`.

To see what macOS has granted without triggering any prompt:

```bash
open -n build/Parallax.app --args --permission-report /tmp/parallax-permissions.txt
```

## Command Line Tools only (no Xcode)

`scripts/env.sh` builds against the macOS 26 SDK, because the 27 SDK's SwiftUI `@State` macro needs a plugin that ships only with Xcode. It also points `swift test` at the swift-testing macro plugin. With Xcode installed, neither workaround applies.
