<p align="center">
  <img src="Krevo/Krevo/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="128" height="128" alt="Krevo" />
</p>

<h1 align="center">Krevo for Mac</h1>

<p align="center">
  <strong>Upload files at full speed. Right from your menu bar.</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS%2026.2+-black?style=flat-square" />
  <img src="https://img.shields.io/badge/swift-5.0-black?style=flat-square" />
  <img src="https://img.shields.io/badge/UI-SwiftUI-black?style=flat-square" />
  <img src="https://img.shields.io/badge/license-proprietary-black?style=flat-square" />
</p>

---

## Architecture

```
Menu Bar Icon
    │
    ▼
┌─────────────────────────────────────┐
│  Popover (320px)                    │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  Storage Meter                │  │
│  │  ████████████░░░  2.1 / 3 TB │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  Drop Zone                    │  │
│  │  Drag files or click to pick  │  │
│  └───────────────────────────────┘  │
│                                     │
│  ┌───────────────────────────────┐  │
│  │  render_v4.mov   ████░░ 62%  │  │
│  │  1.8 GB/s · 4s remaining     │  │
│  └───────────────────────────────┘  │
│                                     │
│  Pro · jonas@krevo.io    Sign Out   │
└─────────────────────────────────────┘
```

## Upload Engine

The core of the app. Files upload **directly to R2** via presigned URLs — bytes never touch our servers.

| Spec | Value |
|------|-------|
| Concurrent streams | 20 (HTTP/2 multiplexed) |
| Max file size | 5 TB |
| Chunk sizing | Adaptive: 16 MB → 500 MB |
| Retry strategy | 6 attempts, exponential backoff + jitter |
| Stall detection | 60s inactivity timeout per chunk |
| Progress tracking | Per-chunk byte-level (URLSession delegate) |
| Speed smoothing | EWMA (alpha 0.3) |
| URL prefetching | Predictive at 75% cache consumption |
| Resume | Persisted state + security-scoped bookmarks |

### How it works

```
1. POST /api/r2/upload/init
   → { fileId, uploadId, key, presignedUrls[0..127] }

2. TaskGroup: 20 concurrent chunks
   │
   ├─ pread() from disk (zero-copy, no mmap overhead)
   ├─ PUT chunk → R2 presigned URL (HTTP/2)
   ├─ Capture ETag
   └─ Report bytesWritten via URLSession delegate

3. POST /api/r2/upload/complete
   → { success, fileId, size }
```

### File I/O

```swift
// Zero-copy reads via pread(2) — thread-safe, no locking needed
let buffer = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 1)
pread(fd, buffer, length, offset)
return Data(bytesNoCopy: buffer, count: length, deallocator: .custom { ptr, _ in ptr.deallocate() })
```

No zero-fill. No memcpy. The kernel reads from disk directly into our buffer, which is handed to URLSession without copying.

## Auth

```
Mac App                          Browser                         Krevo API
   │                                │                                │
   ├─ ASWebAuthenticationSession ──▶│                                │
   │                                ├─ Clerk sign-in ───────────────▶│
   │                                │◀─────────────── session ───────┤
   │                                ├─ POST /api/auth/device-token ─▶│
   │                                │◀──────────── { token } ────────┤
   │◀── krevo://auth?token=xxx ─────┤                                │
   │                                                                 │
   ├─ Store in Keychain                                              │
   ├─ X-Device-Token on all requests ──────────────────────────────▶│
```

Device tokens are long-lived, stored as SHA-256 hashes in the database, and revocable from the web dashboard.

## Project Structure

```
Krevo/Krevo/
├── KrevoApp.swift              App entry + MenuBarExtra + URL scheme handler
├── Core/
│   ├── AppState.swift          Singleton observable state
│   ├── Constants.swift         Upload tuning parameters
│   ├── KeychainService.swift   Secure token storage
│   └── KrevoAPIClient.swift    Actor-based HTTP client (dual URLSession)
├── Auth/
│   ├── AuthManager.swift       ASWebAuthenticationSession flow
│   └── AuthView.swift          Sign-in screen
├── Upload/
│   ├── UploadEngine.swift      Orchestrator (TaskGroup + PresignedURLCache actor)
│   ├── UploadTask.swift        Per-file state machine + EWMA speed tracking
│   ├── ChunkUploader.swift     Single-chunk retry loop with stall detection
│   └── FileChunkReader.swift   pread-based zero-copy file I/O
└── Views/
    ├── MenuBarView.swift       Main popover layout
    ├── UploadDropZone.swift    Drag & drop + NSOpenPanel
    ├── UploadProgressView.swift Per-file progress with speed/ETA
    ├── StorageMeterView.swift  Usage bar with gradient
    └── Components/
        ├── KrevoButton.swift
        ├── AnimatedProgress.swift
        └── ColorExtension.swift
```

## Concurrency Model

```
MainActor                    UploadEngine (actor)         PresignedURLCache (actor)
    │                              │                              │
    │  startUpload(urls)           │                              │
    ├─────────────────────────────▶│                              │
    │                              ├─ TaskGroup (20 slots)        │
    │                              │   ├─ chunk 1 ───────────────▶│ resolve URL
    │                              │   ├─ chunk 2 ───────────────▶│ resolve URL
    │                              │   └─ ...                     │
    │◀─ throttled progress (5/s) ──┤                              │
    │                              │                              ├─ prefetch at 75%
    │  updatePartialProgress()     │                              │
    │  (per-chunk byte-level)      │                              │
```

- `UploadEngine` — actor, owns active operations, delegates URL resolution to per-upload cache actors
- `PresignedURLCache` — per-upload actor, coalesces concurrent cache misses, prefetches at 75%
- `KrevoAPIClient.uploadChunkWithProgress()` — `nonisolated`, no actor hop for chunk uploads
- `ProgressThrottle` — caps MainActor dispatches to 5/sec

## Build

```bash
cd Krevo
xcodebuild -project Krevo.xcodeproj -scheme Krevo -configuration Debug build
```

Requires Xcode 26.2+. The app targets macOS 26.2. Signing team: `VJX635MVWF`.

## Config

| Key | Value |
|-----|-------|
| Bundle ID | `io.krevo.mac` |
| URL Scheme | `krevo://` |
| Dock Icon | Hidden (`LSUIElement = true`) |
| Sandbox | Enabled (network client + user-selected files) |
| API Base | `https://www.krevo.io/api` |
| Auth Bridge | `https://www.krevo.io/mac-auth` |

## Backend Dependencies

The Mac app talks to the existing Krevo API. Backend additions for Mac support:

| Endpoint | Purpose |
|----------|---------|
| `POST /api/auth/device-token` | Generate long-lived auth token |
| `DELETE /api/auth/device-token` | Revoke token (sign out) |
| `GET /mac-auth` | Clerk sign-in bridge → `krevo://` redirect |
| `X-Device-Token` header | Auth fallback in all API routes |

These live in the main [Graphite](https://github.com/Cloverings1/Graphite) repo.

---

<p align="center">
  <sub>Internal repository. Customer-facing product.</sub>
</p>
