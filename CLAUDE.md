# KrevoMac — Claude Reference

## What this app is

Krevo for Mac is a macOS menu bar utility that uploads files to Krevo's cloud storage (Cloudflare R2) at high speed. Files go directly to R2 via presigned URLs — bytes never pass through the Krevo API server.

## Commit policy

- Each logical fix or change gets its own atomic commit
- Commit messages follow conventional format: `fix:`, `feat:`, `docs:`, `refactor:`
- Each commit must build cleanly with `xcodebuild`
- Push all commits together at the end of a session

## Build

```bash
cd Krevo
xcodebuild -project Krevo.xcodeproj -scheme Krevo -configuration Debug build
```

- macOS 26.2+ deployment target, Xcode 26.2

## Release builds

Release builds go to `/Users/jonas/Desktop/krevomac/builds/` with versioned directories.

```bash
# Build a release candidate
cd Krevo
xcodebuild -project Krevo.xcodeproj -scheme Krevo -configuration Release build \
  CONFIGURATION_BUILD_DIR=/Users/jonas/Desktop/krevomac/builds/<version>
```

- Version format: `1.0`, `1.1`, `1.2`, etc. (increment minor for each build)
- Directory naming: `builds/<version>/` (e.g. `builds/1.0/`)
- When asked to "make a build", create the next version number in sequence
- Current latest: **1.0 Beta**
- Zero third-party dependencies — Apple frameworks only
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` is set project-wide

## Project structure

```
Krevo/Krevo/
  KrevoApp.swift           # @main entry, AppDelegate (URL scheme handler + termination)
  Info.plist               # LSUIElement=true (no dock icon), krevo:// URL scheme
  Krevo.entitlements       # Sandbox, network.client, files.user-selected.read-only
  Core/
    Constants.swift        # All tuning knobs, URLs, os.Logger instances
    AppState.swift         # @Observable @MainActor singleton — central state hub
    KeychainService.swift  # Token CRUD via Security framework
    KrevoAPIClient.swift   # actor — HTTP client + ChunkUploadDelegate
  Auth/
    AuthManager.swift      # ASWebAuthenticationSession → Clerk → device token
    AuthView.swift         # Sign-in UI
  Upload/
    UploadEngine.swift     # actor — orchestrates chunked multipart uploads
    UploadTask.swift       # @Observable @MainActor — per-file state machine
    ChunkUploader.swift    # Exponential backoff retry loop per chunk
    FileChunkReader.swift  # pread(2) zero-copy reads + integrity validation
  Views/
    MenuBarView.swift      # Root popover (320px wide, 420px max scroll)
    UploadDropZone.swift   # Drag-and-drop + NSOpenPanel
    UploadProgressView.swift
    StorageMeterView.swift
    Components/            # KrevoButton, AnimatedProgress, ColorExtension
```

## Architecture

**Concurrency model:**
- `AppState` is `@Observable @MainActor` — all UI state lives here
- `KrevoAPIClient` and `UploadEngine` are Swift `actor`s
- `PresignedURLCache` (private, inside UploadEngine.swift) is a per-upload `actor`
- `UploadTask` is `@Observable @MainActor` — bound directly by SwiftUI views
- `FileChunkReader` is `nonisolated final class @unchecked Sendable` — `pread` is thread-safe
- `uploadChunk` / `uploadChunkWithProgress` on `KrevoAPIClient` are `nonisolated` — avoid serializing 20 concurrent chunk uploads through the actor executor

**Upload flow:**
1. `AppState.startUpload(urls:)` — pre-flight checks (size, quota), then queues tasks
2. `drainQueue()` — launches up to `KrevoConstants.maxConcurrentUploads` (3) at once
3. `UploadEngine.executeUpload` — calls `initUpload`, opens `FileChunkReader`, creates `PresignedURLCache`
4. `TaskGroup` with adaptive concurrency (`min(20, maxMemoryBudget / chunkSize)`) uploads chunks in parallel
5. Each chunk goes through `ChunkUploader.upload()` — 6 retries, 0.5s–30s exponential backoff with jitter
6. `completeUpload` finalizes; `AppState.handleUploadCompletion` refreshes storage meter

**Auth flow:**
`ASWebAuthenticationSession` → `https://www.krevo.io/mac-auth` (Clerk) → server creates device token → redirects to `krevo://auth?token=xxx` → `AppDelegate.handleGetURL` → `AppState.signIn(token:)` → Keychain

## Key constants (Constants.swift)

| Constant | Value | Notes |
|---|---|---|
| `maxConcurrentUploads` | 3 | File-level queue in AppState |
| `maxConcurrentChunks` | 20 | Chunk-level parallelism per upload |
| `maxMemoryBudget` | 500 MB | Caps adaptive chunk concurrency |
| `maxRetries` | 6 | Per-chunk retry attempts |
| `retryBaseDelay` | 0.5s | Doubles each attempt, capped at 30s |
| `chunkTimeout` | 600s | Per-chunk session timeout |
| `presignedURLExpiry` | 48h | URLs batch-prefetched at 75% consumption |

## Patterns to follow

**Adding a new API endpoint:** Add a method to `KrevoAPIClient` using `makeRequest(method:path:body:)`. Define request/response structs as private inner types. Map new error codes in `mapError`.

**Adding new observable state:** Add properties to `AppState`. They are automatically observed by SwiftUI views via `@Observable`. No need for `@Published`.

**Adding a new view:** Use `@Environment(AppState.self) private var appState` to access state. Keep views passive — mutations go through `AppState` methods, not directly on tasks.

**Logging:** Use the loggers from `KrevoConstants`, not `print()`:
```swift
KrevoConstants.logger.info("...")       // general
KrevoConstants.authLogger.error("...")  // auth events
KrevoConstants.uploadLogger.debug("...") // upload events
```

**Error handling:** Surface errors to the user by creating a failed `UploadTask`:
```swift
let failed = UploadTask(failedURL: url, message: "Human-readable reason")
uploadTasks.insert(failed, at: 0)
```

## What NOT to do

- **Don't add third-party dependencies** — the zero-dep policy is intentional
- **Don't use `DispatchQueue.main.async`** — use `await MainActor.run { }` or `Task { @MainActor in }`
- **Don't use `DispatchSemaphore` or `DispatchGroup`** — use structured concurrency (`async/await`, `TaskGroup`, `withCheckedContinuation`)
- **Don't add `@Published`** — the project uses `@Observable`, not `ObservableObject`
- **Don't bypass the upload queue** — always go through `pendingQueue` / `drainQueue()`, never fire a `Task` directly in `startUpload`
- **Don't use `@vercel/kv` or `@vercel/postgres`** — not relevant; this is a native macOS app
- **Don't use `UserDefaults` for the auth token** — it must stay in Keychain

## API endpoints

All hit `https://www.krevo.io/api` with `X-Device-Token` header.

| Path | Method | Purpose |
|---|---|---|
| `/storage` | GET | Validate token + get storage info |
| `/auth/device-token` | DELETE | Revoke token on sign-out |
| `/r2/upload/init` | POST | Start multipart upload, get presigned URLs |
| `/r2/upload/complete` | POST | Finalize upload |
| `/r2/upload/refresh-urls` | POST | Fetch more presigned URLs |
| `/r2/upload/abort` | POST | Abort and free quota |

Chunks upload directly to R2 via `PUT` to presigned URLs (no auth header).

## Known pre-existing warnings (safe to ignore)

```
no 'async' operations occur within 'await' expression  (UploadEngine.swift)
'nonisolated(unsafe)' is unnecessary for Sendable URLSession  (KrevoAPIClient.swift)
initialization of immutable value 'chunkSize' was never used  (UploadEngine.swift)
```

## Deferred / not yet implemented

- Upload resume after relaunch (needs state persistence + security-scoped bookmarks)
- Sleep/wake explicit handling (existing retry loop handles this adequately)
- Tests (all test files are Xcode-generated stubs; retry/progress math has unit tests)
- Full keyboard navigation in the popover
- Certificate pinning for enterprise (currently relies on OS validation)
- Adaptive chunk timeout based on TTFB
- Global memory budget coordinator across concurrent uploads
