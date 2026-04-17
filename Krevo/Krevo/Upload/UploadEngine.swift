import Foundation
import UniformTypeIdentifiers
import os

/// Thread-safe presigned URL cache for a single upload.
/// Each upload gets its own instance so concurrent uploads never interfere.
/// URL resolution serializes only within this cache — not on the UploadEngine actor.
///
/// Includes predictive prefetching: when resolved part numbers exceed 75% of the
/// cached high-water mark, a background batch refresh is kicked off so URLs are
/// ready before the upload tasks need them.
private actor PresignedURLCache {
    private struct CachedURL {
        let url: URL
        let fetchedAt: ContinuousClock.Instant
    }

    private var urls: [Int: CachedURL]
    private let uploadId: String
    private let key: String
    private let totalChunks: Int
    private let apiClient: KrevoAPIClient

    /// Max age before a URL is considered near-expiry and evicted.
    private let maxAge: Duration

    /// Tracks an in-flight refresh so concurrent cache misses coalesce into one request.
    private var inflightRefresh: Task<Void, any Error>?
    private var inflightRange: ClosedRange<Int>?

    /// Background prefetch task — at most one in flight at a time.
    private var prefetchTask: Task<Void, any Error>?

    init(
        uploadId: String,
        key: String,
        totalChunks: Int,
        initial: [PresignedURL],
        apiClient: KrevoAPIClient
    ) {
        self.uploadId = uploadId
        self.key = key
        self.totalChunks = totalChunks
        self.apiClient = apiClient
        self.maxAge = .seconds(KrevoConstants.presignedURLExpiry - KrevoConstants.presignedURLSafetyMargin)

        let now = ContinuousClock.now
        var map: [Int: CachedURL] = [:]
        for pu in initial {
            if let url = URL(string: pu.url) {
                map[pu.partNumber] = CachedURL(url: url, fetchedAt: now)
            }
        }
        self.urls = map
    }

    /// Resolve a presigned URL for the given part number.
    /// On cache miss, fetches a batch starting at `partNumber`.
    /// Concurrent misses within the same batch coalesce into a single network request.
    ///
    /// After resolving, triggers predictive prefetch if we're approaching the cache boundary.
    /// Check if a cached URL is still valid (not near expiry).
    private func validURL(for partNumber: Int) -> URL? {
        guard let cached = urls[partNumber] else { return nil }
        if ContinuousClock.now - cached.fetchedAt >= maxAge {
            urls.removeValue(forKey: partNumber) // Evict near-expiry URL
            return nil
        }
        return cached.url
    }

    func resolve(partNumber: Int) async throws -> URL {
        // Fast path: already cached and not near expiry
        if let url = validURL(for: partNumber) {
            triggerPrefetchIfNeeded(currentPart: partNumber)
            return url
        }

        // Determine the batch range we need
        let endPart = min(partNumber + KrevoConstants.urlRefreshBatchSize - 1, totalChunks)

        // If there's an in-flight refresh that covers our part number, wait for it
        if let inflight = inflightRefresh,
           let range = inflightRange,
           range.contains(partNumber)
        {
            try await inflight.value
            if let url = validURL(for: partNumber) {
                triggerPrefetchIfNeeded(currentPart: partNumber)
                return url
            }
            // Fall through to fetch if the inflight didn't cover us after all
        }

        // Wait for any prefetch that might have our part
        if let prefetch = prefetchTask {
            try? await prefetch.value
            if let url = validURL(for: partNumber) {
                triggerPrefetchIfNeeded(currentPart: partNumber)
                return url
            }
        }

        // Build the list of parts we still need (validURL already evicted near-expiry entries)
        let needed = (partNumber...endPart).filter { validURL(for: $0) == nil }
        guard !needed.isEmpty else {
            throw KrevoAPIError.serverError(
                statusCode: 500,
                message: "Failed to resolve presigned URL for part \(partNumber)"
            )
        }

        // Launch the refresh and store it so concurrent callers can coalesce
        let capturedUploadId = uploadId
        let capturedKey = key
        let capturedApiClient = apiClient
        let capturedNeeded = Array(needed)
        let range = partNumber...endPart

        let refresh = Task {
            let freshURLs = try await withThrowingTaskGroup(of: [PresignedURL].self) { group in
                group.addTask {
                    try await capturedApiClient.refreshPresignedURLs(
                        uploadId: capturedUploadId,
                        key: capturedKey,
                        partNumbers: capturedNeeded
                    )
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(KrevoConstants.urlRefreshTimeout))
                    throw KrevoAPIError.networkError("Presigned URL refresh timed out after \(Int(KrevoConstants.urlRefreshTimeout))s")
                }
                let result = try await group.next()!
                group.cancelAll()
                return result
            }

            self.storeRefreshedURLs(freshURLs)
        }

        inflightRefresh = refresh
        inflightRange = range
        defer {
            inflightRefresh = nil
            inflightRange = nil
        }

        try await refresh.value

        guard let url = validURL(for: partNumber) else {
            throw KrevoAPIError.serverError(
                statusCode: 500,
                message: "Failed to get presigned URL for part \(partNumber)"
            )
        }

        triggerPrefetchIfNeeded(currentPart: partNumber)
        return url
    }

    // MARK: - Predictive Prefetching

    /// When the current part exceeds 75% of the highest cached part, prefetch the
    /// next batch in the background so URLs are ready before upload tasks need them.
    private func triggerPrefetchIfNeeded(currentPart: Int) {
        let cacheHighPart = urls.keys.max() ?? 0

        // Only prefetch if we're past the 75% mark and there are more chunks
        guard cacheHighPart < totalChunks else { return }
        guard currentPart > Int(Double(cacheHighPart) * 0.75) else { return }
        guard prefetchTask == nil else { return } // Already prefetching

        let start = cacheHighPart + 1
        let end = min(start + KrevoConstants.urlRefreshBatchSize - 1, totalChunks)
        let needed = (start...end).filter { validURL(for: $0) == nil }
        guard !needed.isEmpty else { return }

        let capturedUploadId = uploadId
        let capturedKey = key
        let capturedApiClient = apiClient
        let capturedNeeded = Array(needed)

        prefetchTask = Task {
            do {
                let freshURLs = try await withThrowingTaskGroup(of: [PresignedURL].self) { group in
                    group.addTask {
                        try await capturedApiClient.refreshPresignedURLs(
                            uploadId: capturedUploadId,
                            key: capturedKey,
                            partNumbers: capturedNeeded
                        )
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(KrevoConstants.urlRefreshTimeout))
                        throw KrevoAPIError.networkError("Prefetch timed out")
                    }
                    let result = try await group.next()!
                    group.cancelAll()
                    return result
                }
                self.storeRefreshedURLs(freshURLs)
            } catch {
                KrevoConstants.uploadLogger.warning("Presigned URL prefetch failed: \(error.localizedDescription)")
            }
            self.prefetchTask = nil
        }
    }

    private func storeRefreshedURLs(_ freshURLs: [PresignedURL]) {
        let now = ContinuousClock.now
        for pu in freshURLs {
            if let url = URL(string: pu.url) {
                urls[pu.partNumber] = CachedURL(url: url, fetchedAt: now)
            }
        }
    }

    func invalidate(partNumber: Int) {
        urls.removeValue(forKey: partNumber)
    }
}

/// Core upload engine. Orchestrates chunked multipart uploads to R2 via presigned URLs.
///
/// All per-upload state (presigned URL cache, chunk index) is local to each `executeUpload`
/// call or stored in a dedicated `PresignedURLCache` actor, so concurrent uploads never
/// interfere with each other. Cancellation is handled by storing the real work task.
actor UploadEngine {
    private struct InitializedUploadContext: Sendable {
        let uploadId: String
        let key: String
        let size: Int64
    }

    private let apiClient: KrevoAPIClient
    private let chunkUploader: ChunkUploader
    private var activeOperations: [UUID: Task<Void, Never>] = [:]

    init(apiClient: KrevoAPIClient) {
        self.apiClient = apiClient
        self.chunkUploader = ChunkUploader(apiClient: apiClient)
    }

    // MARK: - Upload File

    /// Upload a file. The actual work is wrapped in a stored Task so `cancelUpload`
    /// can cancel it and the TaskGroup tears down promptly.
    func uploadFile(task: UploadTask) async {
        let taskId = task.id
        let operation = Task {
            await executeUpload(task: task)
        }
        activeOperations[taskId] = operation
        await operation.value
        activeOperations.removeValue(forKey: taskId)
    }

    /// Execute the full upload pipeline for a single file.
    /// All per-upload state (URL cache, chunk index) is local — no shared actor properties.
    private func executeUpload(task: UploadTask) async {
        let taskFileName = await MainActor.run { task.fileName }
        var initializedUpload: InitializedUploadContext?
        await MainActor.run { task.state = .initializing }

        do {
            try Task.checkCancellation()

            let fileSize = task.fileSize
            let contentType = Self.mimeType(for: task.fileURL)

            // 1. Init upload on server
            let initResponse = try await apiClient.initUpload(
                filename: task.fileName,
                size: fileSize,
                contentType: contentType,
                parentId: nil
            )

            KrevoConstants.uploadLogger.info("Upload initialized: \(initResponse.totalChunks) chunks, \(initResponse.chunkSize) bytes/chunk, uploadId=\(initResponse.uploadId)")

            // Validate server response before proceeding
            guard !initResponse.uploadId.isEmpty, !initResponse.key.isEmpty else {
                throw KrevoAPIError.serverError(statusCode: 500, message: "Server returned empty upload identifiers")
            }
            initializedUpload = InitializedUploadContext(
                uploadId: initResponse.uploadId,
                key: initResponse.key,
                size: fileSize
            )
            guard initResponse.totalChunks > 0 else {
                throw KrevoAPIError.serverError(statusCode: 500, message: "Server returned zero chunks for upload")
            }
            guard initResponse.chunkSize > 0 else {
                throw KrevoAPIError.serverError(statusCode: 500, message: "Server returned zero chunk size")
            }

            try Task.checkCancellation()

            // Store upload identifiers for cancellation
            await MainActor.run {
                task.uploadId = initResponse.uploadId
                task.uploadKey = initResponse.key
            }

            // 2. Open file reader
            let reader = try FileChunkReader(
                url: task.fileURL,
                chunkSize: initResponse.chunkSize
            )
            let totalChunks = initResponse.totalChunks

            await MainActor.run {
                task.totalChunks = totalChunks
                task.state = .uploading
                task.startTime = Date()
            }

            // 3. Per-upload presigned URL cache (dedicated actor — no serialization on UploadEngine)
            let urlCache = PresignedURLCache(
                uploadId: initResponse.uploadId,
                key: initResponse.key,
                totalChunks: totalChunks,
                initial: initResponse.presignedUrls,
                apiClient: apiClient
            )

            // 4. Per-upload chunk index — local to this function, protected by UploadEngine actor
            var nextChunkIndex = 0
            func claimNextChunk() -> Int? {
                guard nextChunkIndex < totalChunks else { return nil }
                let idx = nextChunkIndex
                nextChunkIndex += 1
                return idx
            }

            // 5. Compute adaptive concurrency
            let concurrency = min(
                KrevoConstants.maxConcurrentChunks,
                max(1, KrevoConstants.maxMemoryBudget / initResponse.chunkSize)
            )

            // 6. Progress throttle — shared across all chunk progress callbacks for this upload.
            //    Only forwards partial-byte updates to the MainActor if 100ms+ have elapsed,
            //    preventing excessive main-thread hops from high-frequency delegate callbacks.
            final class ProgressThrottle: @unchecked Sendable {
                private let lock = NSLock()
                private var _lastUpdate: ContinuousClock.Instant = .now - .seconds(1)

                var lastUpdate: ContinuousClock.Instant {
                    get { lock.withLock { _lastUpdate } }
                    set { lock.withLock { _lastUpdate = newValue } }
                }

                /// Returns true if enough time has passed to dispatch a UI update.
                func shouldUpdate() -> Bool {
                    let now = ContinuousClock.now
                    return lock.withLock {
                        let elapsed = now - _lastUpdate
                        if elapsed >= .milliseconds(100) {
                            _lastUpdate = now
                            return true
                        }
                        return false
                    }
                }
            }
            let throttle = ProgressThrottle()

            actor ProgressCoordinator {
                private var pendingPartials: [Int: Int64] = [:]
                private var lastFlush: ContinuousClock.Instant = .now - .seconds(1)

                func record(partNumber: Int, bytesSent: Int64) {
                    pendingPartials[partNumber] = bytesSent
                }

                func reset(partNumber: Int) {
                    pendingPartials.removeValue(forKey: partNumber)
                }

                func flushIfNeeded(force: Bool = false) -> [Int: Int64]? {
                    let now = ContinuousClock.now
                    let elapsed = now - lastFlush
                    guard force || elapsed >= .milliseconds(125) else { return nil }
                    guard !pendingPartials.isEmpty else {
                        lastFlush = now
                        return nil
                    }

                    let snapshot = pendingPartials
                    pendingPartials.removeAll(keepingCapacity: true)
                    lastFlush = now
                    return snapshot
                }
            }
            let progressCoordinator = ProgressCoordinator()

            // Helper: creates a chunk upload closure with byte-level progress tracking.
            func uploadChunk(
                idx: Int,
                partNumber: Int,
                chunkUploader: ChunkUploader,
                task: UploadTask
            ) async throws -> CompletedPart {
                try Task.checkCancellation()
                let chunkData = try reader.readChunk(at: idx)
                let chunkSizeBytes = Int64(chunkData.count)
                let maxPresignedURLRefreshAttempts = 2
                var refreshAttempts = 0

                while true {
                    try Task.checkCancellation()
                    let url = try await urlCache.resolve(partNumber: partNumber)

                    do {
                        let etag = try await chunkUploader.upload(
                            data: chunkData,
                            to: url,
                            partNumber: partNumber,
                            onProgress: { [throttle] bytesSent in
                                guard throttle.shouldUpdate() else { return }
                                Task {
                                    await progressCoordinator.record(partNumber: partNumber, bytesSent: bytesSent)
                                    guard let pending = await progressCoordinator.flushIfNeeded() else { return }
                                    await MainActor.run {
                                        for (partNumber, bytesSent) in pending {
                                            task.updatePartialProgress(
                                                partNumber: partNumber,
                                                bytesSent: bytesSent
                                            )
                                        }
                                        task.updateSpeed()
                                    }
                                }
                            },
                            onRetry: { partNumber in
                                Task {
                                    await progressCoordinator.reset(partNumber: partNumber)
                                    await MainActor.run {
                                        task.resetPartialProgress(partNumber: partNumber)
                                    }
                                }
                            }
                        )

                        await MainActor.run {
                            task.markChunkCompleted(
                                partNumber: partNumber,
                                chunkSize: chunkSizeBytes
                            )
                        }

                        return CompletedPart(etag: etag, partNumber: partNumber)
                    } catch KrevoAPIError.stalePresignedURL {
                        guard refreshAttempts < maxPresignedURLRefreshAttempts else {
                            throw KrevoAPIError.stalePresignedURL
                        }

                        refreshAttempts += 1
                        await urlCache.invalidate(partNumber: partNumber)
                        await progressCoordinator.reset(partNumber: partNumber)
                        await MainActor.run {
                            task.resetPartialProgress(partNumber: partNumber)
                        }

                        KrevoConstants.uploadLogger.warning(
                            "Chunk \(partNumber) presigned URL became invalid. Refreshing URL (\(refreshAttempts)/\(maxPresignedURLRefreshAttempts))"
                        )
                    }
                }
            }

            // 7. Pre-upload integrity check
            try reader.validateIntegrity()

            // 8. Upload chunks with TaskGroup (limited concurrency)
            var completedParts: [CompletedPart] = []

            try await withThrowingTaskGroup(of: CompletedPart.self) { group in
                // Seed initial concurrent tasks
                let seedCount = min(concurrency, totalChunks)
                for _ in 0..<seedCount {
                    guard let idx = claimNextChunk() else { break }
                    let partNumber = idx + 1 // R2 parts are 1-indexed

                    group.addTask { [chunkUploader] in
                        try await uploadChunk(
                            idx: idx,
                            partNumber: partNumber,
                            chunkUploader: chunkUploader,
                            task: task
                        )
                    }
                }

                // As each task completes, enqueue the next chunk
                for try await part in group {
                    completedParts.append(part)

                    // Chunk-completion progress: always update on first and last,
                    // throttled otherwise (the per-byte callbacks handle intermediate updates)
                    let count = completedParts.count
                    let isFirst = count == 1
                    let isLast = count == totalChunks
                    let now = ContinuousClock.now
                    let elapsed = now - throttle.lastUpdate

                    if isFirst || isLast || elapsed >= .milliseconds(200) {
                        throttle.lastUpdate = now
                        if let pending = await progressCoordinator.flushIfNeeded(force: true) {
                            await MainActor.run {
                                for (partNumber, bytesSent) in pending {
                                    task.updatePartialProgress(
                                        partNumber: partNumber,
                                        bytesSent: bytesSent
                                    )
                                }
                                task.completedChunks = count
                            }
                        } else {
                            await MainActor.run {
                                task.completedChunks = count
                            }
                        }
                    }

                    // Add next chunk if available
                    if let idx = claimNextChunk() {
                        let partNumber = idx + 1

                        group.addTask { [chunkUploader] in
                            try await uploadChunk(
                                idx: idx,
                                partNumber: partNumber,
                                chunkUploader: chunkUploader,
                                task: task
                            )
                        }
                    }
                }
            }

            try Task.checkCancellation()

            // Post-upload integrity check
            try reader.validateIntegrity()

            // 9. Complete upload
            await MainActor.run { task.state = .completing }

            let sortedParts = completedParts.sorted { $0.partNumber < $1.partNumber }
            let completeResponse = try await apiClient.completeUpload(
                uploadId: initResponse.uploadId,
                key: initResponse.key,
                parts: sortedParts,
                filename: task.fileName,
                size: fileSize,
                contentType: contentType,
                parentId: nil
            )
            initializedUpload = nil

            let shareURL = completeResponse.shareURL ?? "https://www.krevo.io/file/\(completeResponse.fileId)"
            await MainActor.run { task.markCompleted(fileId: completeResponse.fileId, shareURL: shareURL) }

        } catch is CancellationError {
            await abortRemoteUpload(initializedUpload, context: "cancellation for \(taskFileName)")
            KrevoConstants.uploadLogger.info("Upload cancelled: \(taskFileName)")
            await MainActor.run { task.markCancelled() }
        } catch {
            await abortRemoteUpload(initializedUpload, context: "failed upload for \(taskFileName)")
            KrevoConstants.uploadLogger.error("Upload failed: \(taskFileName) — \(error.localizedDescription)")
            await MainActor.run { task.markFailed(error) }
        }
    }

    // MARK: - Cancel Upload

    func cancelUpload(taskId: UUID, uploadId: String?, key: String?, size: Int64?) async {
        let operation = activeOperations.removeValue(forKey: taskId)
        operation?.cancel()

        // The active upload task owns post-init cleanup. Fall back to a direct abort only
        // if nothing is still running to catch cancellation and release reserved quota.
        if operation == nil, let uploadId, let key, let size {
            await abortRemoteUpload(
                InitializedUploadContext(uploadId: uploadId, key: key, size: size),
                context: "external cancellation fallback for task \(taskId)"
            )
        }
    }

    private func abortRemoteUpload(_ upload: InitializedUploadContext?, context: String) async {
        guard let upload else { return }

        do {
            try await apiClient.abortUpload(
                uploadId: upload.uploadId,
                key: upload.key,
                size: upload.size
            )
            KrevoConstants.uploadLogger.info("Aborted upload \(upload.uploadId) after \(context)")
        } catch {
            KrevoConstants.uploadLogger.warning(
                "Failed to abort upload \(upload.uploadId) after \(context): \(error.localizedDescription)"
            )
        }
    }

    // MARK: - MIME Type Detection

    nonisolated static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()

        if let utType = UTType(filenameExtension: ext),
           let mime = utType.preferredMIMEType
        {
            return mime
        }

        // Fallback for common types UTType might miss
        switch ext {
        case "mp4": return "video/mp4"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "wav": return "audio/wav"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "dmg": return "application/x-apple-diskimage"
        case "psd": return "image/vnd.adobe.photoshop"
        case "ai": return "application/postscript"
        case "prproj": return "application/octet-stream"
        case "aep": return "application/octet-stream"
        default: return "application/octet-stream"
        }
    }
}
