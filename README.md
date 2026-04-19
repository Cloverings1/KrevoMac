<div align="center">

<img src="Krevo/Krevo/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png" width="120" height="120" alt="Krevo app icon" />

# Krevo for Mac

**High-speed uploads from your menu bar.**  
Chunked multipart transfers go **straight to Cloudflare R2** — your files never pass through Krevo’s API servers.

<br/>

[![macOS](https://img.shields.io/badge/macOS-26.2%2B-0F172A?style=for-the-badge&logo=apple&logoColor=white)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5.0-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org/)
[![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-0066CC?style=for-the-badge)](https://developer.apple.com/xcode/swiftui/)
[![Zero SPM deps](https://img.shields.io/badge/deps-Apple%20frameworks%20only-334155?style=for-the-badge)](https://developer.apple.com/documentation/)

<br/>

<sub>Bundle ID · <code>io.krevo.mac</code> · version in Xcode target</sub>

</div>

---

<br/>

## Why it feels fast

| | |
|:---|:---|
| **Direct to object storage** | Presigned `PUT` URLs — parallel chunk uploads, not a single pipe through a proxy. |
| **Aggressive parallelism** | Up to **32** concurrent chunk streams and **8** files at once, with adaptive concurrency from live latency. |
| **Connection pool sized for real links** | `URLSession` per-host limits scale with *files × chunks* so streams don’t queue behind each other on the same host. |
| **Disk without drama** | `pread(2)`-based reads; chunk reads scheduled off the upload orchestrator so I/O doesn’t block coordination. |
| **Honest progress** | Byte-level progress via a shared `URLSession` delegate router, throttled so the UI stays smooth under load. |

<br/>

<div align="center">

### Popover at a glance

`360 × 560` · drag-and-drop · storage ring · live speed & ETA · share links · account status

</div>

```
    ◉  Krevo
    │
    ├── Activity  →  uploads in flight, retries, cancel
    ├── Files     →  recent completions & share URLs
    └── Account   →  storage, plan, sign out
```

<br/>

---

<br/>

## Architecture

```mermaid
flowchart LR
    subgraph ui [Menu bar]
        MB[MenuBarExtra]
        POP[SwiftUI popover]
    end

    subgraph state [Concurrency]
        AS[@Observable AppState]
        API[KrevoAPIClient actor]
        UE[UploadEngine actor]
    end

    subgraph upload [Per upload]
        CACHE[PresignedURLCache actor]
        TG[ThrowingTaskGroup chunks]
    end

    MB --> POP --> AS
    AS --> UE
    UE --> API
    UE --> CACHE
    UE --> TG
    TG -->|PUT| R2[(R2 presigned URLs)]
    API -->|HTTPS JSON| KAPI[(krevo.io/api)]
```

- **`AppState`** — `@Observable` hub: queue, storage, auth shell, network reachability, banners.
- **`UploadEngine`** — chunked pipeline, global memory budget for in-flight chunks, adaptive chunk concurrency.
- **`KrevoAPIClient`** — API traffic on one `URLSession`; R2 chunk traffic on dedicated sessions tuned for throughput.

<br/>

---

<br/>

## Upload engine — numbers that match the code

Values come from `KrevoConstants` in **`Core/Constants.swift`** (tune there).

| Topic | Behavior |
|--------|----------|
| **Chunks in flight** | Up to **32** per file (also bounded by a shared **~1.5 GB** reservation pool). |
| **Files in flight** | Up to **8** queued uploads draining concurrently. |
| **R2 connections / host** | Scales with chunk × file concurrency so uploads don’t starve each other. |
| **Adaptive concurrency** | Sliding window of chunk outcomes; scales up when latency stays low, down when failures spike. |
| **Presigned URLs** | Batched refresh (128 parts), predictive prefetch, coalesced cache misses. |
| **Retries** | Up to **6** per chunk, exponential backoff + jitter; stall detection via request timeout. |
| **Resume across relaunch** | Not implemented yet (roadmap item). |

<br/>

---

<br/>

## Auth

Sign-in uses **`ASWebAuthenticationSession`** → **`https://www.krevo.io/mac-auth`** (Clerk) → redirect to **`krevo://auth?token=…`**. The device token is stored in the **Keychain** and sent as **`X-Device-Token`** on API requests. Sign-out revokes remotely and clears local state.

<br/>

---

<br/>

## Repository layout

```
Krevo/
├── Krevo/
│   ├── KrevoApp.swift           App + MenuBarExtra + URL scheme + quit → abort uploads
│   ├── Core/
│   │   ├── AppState.swift       Central observable state
│   │   ├── Constants.swift      Throughput & API tuning
│   │   ├── KrevoAPIClient.swift API + R2 chunk sessions
│   │   ├── KeychainService.swift
│   │   └── UploadHistoryStore.swift
│   ├── Auth/
│   ├── Upload/
│   │   ├── UploadEngine.swift
│   │   ├── UploadTask.swift
│   │   ├── ChunkUploader.swift
│   │   ├── FileChunkReader.swift
│   │   └── FolderExpander.swift
│   └── Views/
├── KrevoTests/
├── KrevoUITests/
└── Krevo.xcodeproj
release/
├── export-app.sh
├── package-dmg.sh
└── verify-local.sh
```

<br/>

---

<br/>

## Build

**Requirements:** Xcode **26.2+**, macOS deployment **26.2+**.

```bash
cd Krevo
xcodebuild -project Krevo.xcodeproj -scheme Krevo -configuration Debug build
```

Open **`Krevo.xcodeproj`** in Xcode and run the **Krevo** scheme for interactive development. Configure your own **Signing & Capabilities** team for local runs.

<br/>

### Verify (debug + unit tests + release into `builds/<version>/`)

```bash
./release/verify-local.sh <version>
```

Unit tests target: **`KrevoTests`**. Finish with a quick menu-bar smoke (open popover, pick/drop files, quit).

<br/>

### Release artifacts

Export and DMG packaging (codesign / notary env vars optional — see scripts):

```bash
./release/export-app.sh <version>
./release/package-dmg.sh <version>
```

Details live in **`AGENTS.md`** and the `release/` scripts.

<br/>

---

<br/>

## Configuration

| | |
|:---|:---|
| **API** | `https://www.krevo.io/api` |
| **Web / dashboard** | `https://www.krevo.io` |
| **Mac auth bridge** | `https://www.krevo.io/mac-auth` |
| **URL scheme** | `krevo://` |
| **Sandbox** | App Sandbox on · outbound network · user-selected files (read) |

<br/>

---

<br/>

## Backend

The Mac client expects the Krevo HTTP API (upload init / complete / refresh / abort, storage, device token, share links, optional client status). Related server work may live alongside your main Krevo / infrastructure repos.

<br/>

---

<div align="center">

**Krevo** · *Ship large files without leaving the menu bar.*

<br/>

<sub>Proprietary · internal & customer-facing product · © Krevo</sub>

</div>
