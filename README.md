# Parallax

A single Mac app to replace an OBS + StreamYard + Loopback/Audio Hijack setup: capture, scenes, audio mixing, local recording, multistreaming, and unified chat.

| Directory | What | Status |
|---|---|---|
| [`client/`](client/) | macOS app (Swift, SwiftUI, AVFoundation, ScreenCaptureKit, Core Image/Metal) | Capture, scenes, mixer, recording, mock chat |
| [`server/`](server/) | Cloud relay (Go): ingest one stream, fan out to platforms, aggregate chat | Stub |
| [`docs/`](docs/) | [Architecture](docs/architecture.md), [client↔server protocol](docs/protocol.md) | |

## Quick start

```bash
client/scripts/build-app.sh debug --open
```

```bash
client/scripts/test.sh
```

Requires macOS 15+ and either Xcode or the Command Line Tools (the scripts handle the CLT-only quirks, see `client/scripts/env.sh`).
