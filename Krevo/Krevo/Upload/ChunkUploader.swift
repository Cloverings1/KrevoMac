import Foundation
import os

/// Uploads a single chunk to a presigned R2 URL with exponential backoff retry.
/// Uses an iterative loop instead of recursion so chunk Data is not pinned on
/// multiple stack frames during backoff sleep.
///
/// The progress-aware overload uses `uploadChunkWithProgress` on a shared session
/// whose request timeout is `KrevoConstants.chunkTimeout`.
nonisolated struct ChunkUploader: Sendable {
    let apiClient: KrevoAPIClient

    /// Upload a single chunk with exponential backoff retry.
    /// Returns the ETag on success.
    func upload(
        data: Data,
        to presignedURL: URL,
        partNumber: Int
    ) async throws -> String {
        try await upload(data: data, to: presignedURL, partNumber: partNumber, onProgress: { _ in })
    }

    /// Upload a single chunk with byte-level progress reporting and exponential backoff retry.
    /// The `onProgress` closure receives `totalBytesSent` on each `didSendBodyData` callback.
    /// The `onRetry` closure is called at the start of each retry to reset partial progress tracking.
    /// Stall detection is handled by the shared upload session's request timeout.
    func upload(
        data: Data,
        to presignedURL: URL,
        partNumber: Int,
        onProgress: @Sendable @escaping (Int64) -> Void,
        onRetry: (@Sendable (Int) -> Void)? = nil
    ) async throws -> String {
        for attempt in 0..<KrevoConstants.maxRetries {
            if attempt > 0 {
                onRetry?(partNumber)
            }

            do {
                return try await apiClient.uploadChunkWithProgress(
                    url: presignedURL,
                    data: data,
                    onProgress: onProgress
                )
            } catch {
                // Don't retry cancellation
                try Task.checkCancellation()

                // Don't retry auth or expiry errors — they won't resolve with retries
                var retryAfterOverride: Double?
                if let apiError = error as? KrevoAPIError {
                    switch apiError {
                    case .unauthorized, .uploadExpired, .stalePresignedURL:
                        throw error
                    case .rateLimited(let retryAfter):
                        retryAfterOverride = Double(retryAfter)
                    default: break
                    }
                }

                if attempt >= KrevoConstants.maxRetries - 1 {
                    KrevoConstants.uploadLogger.error("Chunk \(partNumber) failed after \(KrevoConstants.maxRetries) attempts: \(error.localizedDescription)")
                    throw error
                }

                // Exponential backoff with jitter, respecting server Retry-After
                let baseDelay = KrevoConstants.retryBaseDelay * pow(2.0, Double(attempt))
                let cappedDelay = min(baseDelay, KrevoConstants.retryMaxDelay)
                let jitter = cappedDelay * Double.random(in: 0.8...1.2)
                let delay = if let retryAfter = retryAfterOverride {
                    max(retryAfter, jitter)
                } else {
                    jitter
                }

                KrevoConstants.uploadLogger.warning("Chunk \(partNumber) attempt \(attempt + 1)/\(KrevoConstants.maxRetries) failed: \(error.localizedDescription). Retrying in \(String(format: "%.1f", delay))s")

                try await Task.sleep(for: .seconds(delay))
            }
        }

        // Should never reach here — the loop either returns or throws
        throw KrevoAPIError.networkError("Upload failed after \(KrevoConstants.maxRetries) retries")
    }
}
