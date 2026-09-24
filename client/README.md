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
  - Inspector: preset buttons, a size slider that keeps corner PiPs anchored, fit/fill/stretch, rounded corners (up to circle/pill), border, and crop. Crop trims edges in place: the rest of the image doesn't move or zoom, and the box shrinks to match. The ⇄ button swaps which camera, display, or window a layer shows.
  - Every edit is undoable (⌘Z). A whole drag is one undo step.
- **Layers**: the sources list shows the top layer first. Drag to reorder, + / − to add or remove, and the eye button hides a layer.
- **Audio**: any mic or interface (pick mono or stereo channels) plus system audio. Each input has a gain fader, mute, meter, sync delay (0–2 s), 80 Hz high-pass, and noise gate. The master bus has a limiter.
- **Video delay** per source, 0–2 s.
- **Local recording**: H.264/HEVC + AAC to .mov/.mp4, with configurable bitrate and folder. Files are fragmented, so a crash keeps what was recorded, and quitting finishes the file.
- **Output**: 720p/1080p/1440p at 30/60 fps.
- **Chat and Go Live** run against `MockBroadcastService` until `parallax-server` exists. Set a server URL in Settings to use the real HTTP client.

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
