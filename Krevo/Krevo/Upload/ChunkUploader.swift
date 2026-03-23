import Foundation

/// Uploads a single chunk to a presigned R2 URL with exponential backoff retry.
/// Uses an iterative loop instead of recursion so chunk Data is not pinned on
/// multiple stack frames during backoff sleep.
///
/// The progress-aware overload uses `uploadChunkWithProgress` which creates a
/// per-request URLSession with a 60-second stall timeout — if no data flows for
/// 60 seconds the request times out automatically and the retry loop handles it.
nonisolated struct ChunkUploader: Sendable {
    let apiClient: KrevoAPIClient

    /// Upload a single chunk with exponential backoff retry.
    /// Returns the ETag on success.
    func upload(
        data: Data,
        to presignedURL: URL,
        partNumber: Int
    ) async throws -> String {
        for attempt in 0..<KrevoConstants.maxRetries {
            do {
                return try await apiClient.uploadChunk(url: presignedURL, data: data)
            } catch {
                // Don't retry cancellation
                try Task.checkCancellation()

                if attempt >= KrevoConstants.maxRetries - 1 {
                    throw error
                }

                // Exponential backoff with jitter
                let baseDelay = KrevoConstants.retryBaseDelay * pow(2.0, Double(attempt))
                let cappedDelay = min(baseDelay, KrevoConstants.retryMaxDelay)
                let jitter = cappedDelay * Double.random(in: 0.8...1.2)

                try await Task.sleep(for: .seconds(jitter))
            }
        }

        // Should never reach here — the loop either returns or throws
        throw KrevoAPIError.networkError("Upload failed after \(KrevoConstants.maxRetries) retries")
    }

    /// Upload a single chunk with byte-level progress reporting and exponential backoff retry.
    /// The `onProgress` closure receives `totalBytesSent` on each `didSendBodyData` callback.
    /// Stall detection is handled by the underlying URLSession's 60-second request timeout.
    func upload(
        data: Data,
        to presignedURL: URL,
        partNumber: Int,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> String {
        for attempt in 0..<KrevoConstants.maxRetries {
            do {
                return try await apiClient.uploadChunkWithProgress(
                    url: presignedURL,
                    data: data,
                    onProgress: onProgress
                )
            } catch {
                // Don't retry cancellation
                try Task.checkCancellation()

                if attempt >= KrevoConstants.maxRetries - 1 {
                    throw error
                }

                // Exponential backoff with jitter
                let baseDelay = KrevoConstants.retryBaseDelay * pow(2.0, Double(attempt))
                let cappedDelay = min(baseDelay, KrevoConstants.retryMaxDelay)
                let jitter = cappedDelay * Double.random(in: 0.8...1.2)

                try await Task.sleep(for: .seconds(jitter))
            }
        }

        // Should never reach here — the loop either returns or throws
        throw KrevoAPIError.networkError("Upload failed after \(KrevoConstants.maxRetries) retries")
    }
}
