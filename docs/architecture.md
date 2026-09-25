# Architecture

## Why client + server

Multistreaming from the Mac means uploading the full stream once per platform: 3 destinations at 6 Mbps is 18 Mbps of sustained upload, and one hiccup on home internet hits every platform. Instead:

```
 Mac (Parallax client)                          Cloud (parallax-server)
 ┌──────────────────────────────┐   1 uplink    ┌───────────────────────────┐   RTMP(S)  ┌─ YouTube
 │ capture → compose → encode   │ ────────────▶ │ ingest → relay (no re-enc) │ ─────────▶ ├─ X
 │ local recording (full qual.) │  SRT / RTMP   │                           │            └─ Twitch …
 │ UI: scenes, mixer, chat      │ ◀──────────── │ chat hub + platform OAuth │ ◀── platform chat APIs
 └──────────────────────────────┘  REST + WS    └───────────────────────────┘
```

- **Bandwidth**: the Mac uploads once, and the data center handles the fan-out.
- **Resilience**: per-destination reconnects happen server-side, next to the platforms.
- **Secrets**: platform OAuth tokens and stream keys live on the server. The client holds one bearer token (in the Keychain).
- **Recording stays local** and uses its own encoder at higher bitrate, so uplink trouble never affects the recording.

Costs: roughly 0.5–1 s of extra latency from the extra hop, plus a small VM. Prefer a host with generous included egress (DigitalOcean, Hetzner) over AWS, where egress is billed per GB.

**Server: Rust, with media handled by existing tools.** MediaMTX receives the stream and ffmpeg relays it without re-encoding; the Rust server (axum, tokio) runs them, holds platform sign-ins, and bridges chat. Platforms are added one at a time, starting with Twitch, whose public API covers streaming and chat without partner approval. See [`server/README.md`](../server/README.md).

## Client

```
Camera  ─┐                                                   ┌─▶ PreviewSink   (AVSampleBufferDisplayLayer)
Display ─┼─▶ VideoSourceNode ─▶ VideoFrameBuffer (delay) ─┐  │
Window  ─┤                                                ├─▶ Compositor ─────┼─▶ Recorder      (AVAssetWriter, H.264/HEVC + AAC)
Image / Color / Chat overlays ────────────────────────────┘  (Core Image,   │
                                                              Metal, 30/60)  └─▶ Uplink        (HaishinKit: H.264 + AAC → SRT)
Mic / interface ─┐
System audio ────┴─▶ PCMNormalizer ─▶ DelayBuffer ─▶ ChannelStrip ─▶ AudioMixer ─▶ same sinks
                     (48 kHz float)   (sync delay,   (HPF, gate,     (10 ms chunks,
                                      jitter, drift) gain, mute)     host clock, limiter)
```

Modules (`client/Sources`):

| Module | Responsibility |
|---|---|
| `ParallaxCore` | `Profile` model (sources, scenes, settings), persistence, layout math, DSP. No AVFoundation, so it's fast to unit test. |
| `ParallaxMedia` | Capture nodes, compositor, mixer, recorder, `Uplink` (stream to the server), `MediaEngine`. Everything that consumes the program output is a `MediaSink`. |
| `ParallaxRemote` | Wire types mirroring `server/internal/protocol`, `BroadcastService` protocol, HTTP/websocket client, and a mock. |
| `ParallaxApp` | SwiftUI UI. `AppModel` edits the `Profile`, and `MediaEngine.apply(_:)` reconciles running captures against it. |

Key decisions:

- **Sources are global, scenes reference them.** A camera used in five scenes is captured once, and its delay applies everywhere.
- **Everything runs on the host clock** (`CACurrentMediaTime`). The compositor ticks at the output fps. The mixer pulls 10 ms chunks and absorbs device clock drift in each input's `DelayBuffer`.
- **Delays**: video delay keeps a short history of frames (copied out of the capture pool). Audio delay is a ring-buffer offset, and changing it live inserts silence or drops audio.
- **Chat overlays are just sources.** The engine renders chat into images the compositor places like any other source.

## Roadmap

1. **Uplink**: done. `Uplink` hands the program to HaishinKit, which encodes with VideoToolbox (H.264) and AAC and sends MPEG-TS over SRT.
2. **Server**: SRT ingest, ffmpeg `-c copy` relay, Twitch, and YouTube (sign-in, stream keys, chat both ways) are in. Next: deploy to a VM, then more platforms one at a time.
3. **Replace Loopback / virtual camera**: headphone monitoring output, a CoreMediaIO camera extension (needs Xcode and a signing identity), and possibly a virtual audio device.
4. **Studio polish**: preview/program ("studio mode"), hotkeys, compressor and voice-isolation filters, per-scene audio.

Open question: X's API access for reading and posting live-broadcast chat is limited. Confirm before promising X chat (RTMP ingest to X works either way).
