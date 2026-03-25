import Foundation

// MARK: - Upload State

nonisolated enum UploadState: Sendable {
    case pending
    case initializing
    case uploading
    case completing
    case completed(fileId: String)
    case failed(String) // error message
    case cancelled

    var isActive: Bool {
        switch self {
        case .pending, .initializing, .uploading, .completing: return true
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - Upload Task

@Observable
@MainActor
final class UploadTask: Identifiable {
    let id: UUID
    var fileName: String
    let fileSize: Int64
    let fileURL: URL
    let relativePath: String?

    // Mutable state for UI binding
    var state: UploadState = .pending
    var progress: Double = 0.0
    var uploadedBytes: Int64 = 0
    var speed: Double = 0.0 // bytes per second
    var estimatedTimeRemaining: TimeInterval?
    var startTime: Date?
    var completedChunks: Int = 0
    var totalChunks: Int = 0
    var completionTime: Date?

    // Internal upload state (not for UI)
    var uploadId: String?
    var uploadKey: String?
    var shareURL: String?

    // Per-chunk byte-level progress tracking
    /// Tracks partial bytes sent for each in-flight chunk (partNumber -> bytesSent).
    private var inFlightPartialBytes: [Int: Int64] = [:]
    /// Total bytes from fully completed chunks.
    var completedBytes: Int64 = 0
    /// Running total of all in-flight partial bytes, avoids re-summing the dictionary.
    private var inFlightPartialTotal: Int64 = 0

    // Speed calculation — EWMA smoothing
    private var speedSampleCount: Int = 0
    private var lastSampleTime: Date?
    private var lastSampleBytes: Int64 = 0
    private static let ewmaAlpha: Double = 0.3
    private static let maxSpeedBps: Double = 100_000_000_000 // 100 Gbps upper clamp

    init(fileURL: URL, relativePath: String? = nil) throws {
        self.id = UUID()
        self.fileURL = fileURL
        self.relativePath = relativePath
        self.fileName = relativePath ?? fileURL.lastPathComponent

        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        guard let size = attrs[.size] as? Int64 else {
            throw FileChunkError.readFailed(expected: 0, got: 0)
        }
        self.fileSize = size
    }

    /// Create a task that is immediately in a failed state (e.g. file inaccessible, quota exceeded).
    init(failedURL: URL, message: String, relativePath: String? = nil) {
        self.id = UUID()
        self.fileURL = failedURL
        self.relativePath = relativePath
        self.fileName = relativePath ?? failedURL.lastPathComponent
        let attrs = try? FileManager.default.attributesOfItem(atPath: failedURL.path)
        self.fileSize = (attrs?[.size] as? Int64) ?? 0
        self.state = .failed(message)
    }

    /// Create a display-only task hydrated from a persisted history entry.
    init(historyEntry entry: HistoryEntry) {
        self.id = entry.id
        self.fileURL = URL(fileURLWithPath: "/dev/null")
        self.relativePath = nil
        self.fileName = entry.fileName
        self.fileSize = entry.fileSize
        self.shareURL = entry.shareURL
        self.completionTime = entry.completionTime
        self.state = .completed(fileId: entry.fileId)
    }

    /// Update partial byte-level progress for an in-flight chunk.
    /// Called from the `ChunkUploadDelegate`'s `didSendBodyData` callback (throttled).
    func updatePartialProgress(partNumber: Int, bytesSent: Int64) {
        let previous = inFlightPartialBytes[partNumber] ?? 0
        inFlightPartialBytes[partNumber] = bytesSent
        inFlightPartialTotal += (bytesSent - previous)
        let totalBytes = completedBytes + inFlightPartialTotal
        let clampedBytes = min(totalBytes, fileSize)

        uploadedBytes = clampedBytes
        progress = fileSize > 0 ? Double(clampedBytes) / Double(fileSize) : 1.0

        // EWMA speed calculation
        let now = Date()
        speedSampleCount += 1

        if let prevTime = lastSampleTime {
            let timeDelta = now.timeIntervalSince(prevTime)
            let bytesDelta = clampedBytes - lastSampleBytes

            if timeDelta > 0, bytesDelta >= 0 {
                let instantSpeed = Double(bytesDelta) / timeDelta

                if speedSampleCount >= 3 {
                    if speed == 0 {
                        speed = min(max(instantSpeed, 0), Self.maxSpeedBps)
                    } else {
                        let smoothed = Self.ewmaAlpha * instantSpeed + (1.0 - Self.ewmaAlpha) * speed
                        speed = min(max(smoothed, 0), Self.maxSpeedBps)
                    }

                    let remaining = fileSize - clampedBytes
                    estimatedTimeRemaining = speed > 0 ? Double(remaining) / speed : nil
                }
            }
        }

        lastSampleTime = now
        lastSampleBytes = clampedBytes
    }

    /// Mark a chunk as fully completed. Moves its bytes from in-flight to completed.
    func markChunkCompleted(partNumber: Int, chunkSize: Int64) {
        completedBytes += chunkSize
        let removed = inFlightPartialBytes.removeValue(forKey: partNumber) ?? 0
        inFlightPartialTotal = max(0, inFlightPartialTotal - removed)
        uploadedBytes = min(completedBytes + inFlightPartialTotal, fileSize)
        progress = fileSize > 0 ? Double(uploadedBytes) / Double(fileSize) : 1.0
    }

    /// Reset partial progress for a single chunk part when a retry starts.
    /// Prevents stale bytes from the failed attempt from being double-counted.
    func resetPartialProgress(partNumber: Int) {
        let previous = inFlightPartialBytes[partNumber] ?? 0
        inFlightPartialBytes[partNumber] = 0
        inFlightPartialTotal = max(0, inFlightPartialTotal - previous)
        uploadedBytes = min(completedBytes + inFlightPartialTotal, fileSize)
        progress = fileSize > 0 ? Double(uploadedBytes) / Double(fileSize) : 1.0
        // Reset speed sampling to avoid negative bytesDelta from the byte count regression
        lastSampleTime = nil
        lastSampleBytes = uploadedBytes
    }

    func resetForRetry() {
        state = .pending
        progress = 0
        uploadedBytes = 0
        speed = 0
        estimatedTimeRemaining = nil
        startTime = nil
        completedChunks = 0
        totalChunks = 0
        completionTime = nil
        uploadId = nil
        uploadKey = nil
        completedBytes = 0
        inFlightPartialBytes.removeAll()
        inFlightPartialTotal = 0
        speedSampleCount = 0
        lastSampleTime = nil
        lastSampleBytes = 0
    }

    func markCompleted(fileId: String, shareURL: String? = nil) {
        self.progress = 1.0
        self.uploadedBytes = fileSize
        self.estimatedTimeRemaining = 0
        self.completionTime = Date()
        self.shareURL = shareURL
        self.state = .completed(fileId: fileId)
    }

    func markFailed(_ error: Error) {
        let message: String
        if let apiError = error as? KrevoAPIError {
            message = apiError.localizedDescription
        } else {
            message = error.localizedDescription
        }
        self.state = .failed(message)
        self.speed = 0
        self.estimatedTimeRemaining = nil
        self.completionTime = Date()
    }

    func markCancelled() {
        self.state = .cancelled
        self.speed = 0
        self.estimatedTimeRemaining = nil
        self.completionTime = Date()
    }
}
