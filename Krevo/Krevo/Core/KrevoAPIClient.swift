import Foundation
import os

// MARK: - Error Types

nonisolated enum KrevoAPIError: Error, LocalizedError, Sendable {
    case unauthorized
    case quotaExceeded
    case fileTooLarge(maxBytes: Int64)
    case uploadExpired
    case rateLimited(retryAfter: Int)
    case serverError(statusCode: Int, message: String)
    case networkError(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication required. Please sign in again."
        case .quotaExceeded:
            return "Storage quota exceeded. Upgrade your plan for more space."
        case .fileTooLarge(let maxBytes):
            let gb = Double(maxBytes) / 1_000_000_000
            return String(format: "File exceeds the %.0f GB limit for your plan.", gb)
        case .uploadExpired:
            return "Upload session expired. Please try again."
        case .rateLimited(let retryAfter):
            return "Too many requests. Try again in \(retryAfter) seconds."
        case .serverError(let statusCode, let message):
            return "Server error (\(statusCode)): \(message)"
        case .networkError(let message):
            return "Network error: \(message)"
        }
    }
}

// MARK: - Response Types

nonisolated struct StorageInfo: Codable, Sendable {
    let used: Int64
    let limit: Int64
    let plan: String
    let tier: String
    let maxFileSize: Int64
    let retentionDays: Int
    let name: String?
}

nonisolated struct UploadInitResponse: Codable, Sendable {
    let fileId: String
    let uploadId: String
    let key: String
    let chunkSize: Int
    let totalChunks: Int
    let initialSignedParts: Int
    let presignedUrls: [PresignedURL]
}

nonisolated struct PresignedURL: Codable, Sendable {
    let partNumber: Int
    let url: String
}

nonisolated struct CompletedPart: Codable, Sendable {
    let etag: String
    let partNumber: Int
}

nonisolated struct UploadCompleteResponse: Codable, Sendable {
    let success: Bool
    let fileId: String
    let key: String
    let filename: String
    let size: Int64
    let shareURL: String?
}

// MARK: - API Client

actor KrevoAPIClient {
    private let session: URLSession
    /// Immutable after init — used only by `uploadChunk` which is `nonisolated`.
    /// `nonisolated(unsafe)` is safe here because URLSession is thread-safe and
    /// this property is never mutated after initialization.
    nonisolated(unsafe) private let chunkSession: URLSession
    /// Shared delegate-based session for progress-aware chunk uploads.
    /// Created once in init() — avoids per-chunk session creation overhead.
    nonisolated(unsafe) private let progressSession: URLSession
    /// Routing delegate that dispatches progress/completion callbacks to per-task handlers.
    nonisolated(unsafe) private let progressRouter: ChunkProgressRouter
    private var deviceToken: String?

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .useDefaultKeys
        return d
    }()

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .useDefaultKeys
        return e
    }()

    init() {
        // Session for Krevo API calls (includes default headers)
        let apiConfig = URLSessionConfiguration.default
        apiConfig.httpMaximumConnectionsPerHost = 20
        apiConfig.timeoutIntervalForRequest = 600
        apiConfig.waitsForConnectivity = true
        apiConfig.httpAdditionalHeaders = ["Content-Type": "application/json"]
        self.session = URLSession(configuration: apiConfig)

        // Separate session for direct R2 chunk uploads (no auth headers)
        let chunkConfig = URLSessionConfiguration.default
        chunkConfig.httpMaximumConnectionsPerHost = 20
        chunkConfig.timeoutIntervalForRequest = KrevoConstants.chunkTimeout
        chunkConfig.waitsForConnectivity = true
        self.chunkSession = URLSession(configuration: chunkConfig)

        // Shared delegate-based session for progress-aware chunk uploads
        // Created once — reused across all chunks for all uploads
        let router = ChunkProgressRouter()
        let progressConfig = URLSessionConfiguration.default
        progressConfig.httpMaximumConnectionsPerHost = 20
        progressConfig.timeoutIntervalForRequest = 60
        progressConfig.waitsForConnectivity = true
        self.progressRouter = router
        self.progressSession = URLSession(configuration: progressConfig, delegate: router, delegateQueue: nil)
    }

    func setToken(_ token: String) {
        self.deviceToken = token
    }

    func clearToken() {
        self.deviceToken = nil
    }

    // MARK: - Auth

    func validateToken() async throws -> StorageInfo {
        let (data, _) = try await makeRequest(method: "GET", path: "/storage")
        return try decoder.decode(StorageInfo.self, from: data)
    }

    func revokeToken() async throws {
        _ = try await makeRequest(method: "DELETE", path: "/auth/device-token")
    }

    // MARK: - Client Status

    nonisolated struct ClientStatus: Codable, Sendable {
        let message: String?
        let severity: String? // "info", "warning", "error"
    }

    func getClientStatus() async throws -> ClientStatus {
        let (data, _) = try await makeRequest(method: "GET", path: "/client-status")
        return try decoder.decode(ClientStatus.self, from: data)
    }

    // MARK: - Storage

    func getStorageInfo() async throws -> StorageInfo {
        let (data, _) = try await makeRequest(method: "GET", path: "/storage")
        return try decoder.decode(StorageInfo.self, from: data)
    }

    // MARK: - Upload API

    func initUpload(
        filename: String,
        size: Int64,
        contentType: String,
        parentId: String?
    ) async throws -> UploadInitResponse {
        struct Body: Encodable {
            let filename: String
            let size: Int64
            let contentType: String
            let parentId: String?
        }

        let body = Body(
            filename: filename,
            size: size,
            contentType: contentType,
            parentId: parentId
        )

        let (data, _) = try await makeRequest(method: "POST", path: "/r2/upload/init", body: body)
        return try decoder.decode(UploadInitResponse.self, from: data)
    }

    func completeUpload(
        uploadId: String,
        key: String,
        parts: [CompletedPart],
        filename: String,
        size: Int64,
        contentType: String,
        parentId: String?
    ) async throws -> UploadCompleteResponse {
        struct Body: Encodable {
            let uploadId: String
            let key: String
            let parts: [CompletedPart]
            let filename: String
            let size: Int64
            let contentType: String
            let parentId: String?
        }

        let sortedParts = parts.sorted { $0.partNumber < $1.partNumber }

        let body = Body(
            uploadId: uploadId,
            key: key,
            parts: sortedParts,
            filename: filename,
            size: size,
            contentType: contentType,
            parentId: parentId
        )

        let (data, _) = try await makeRequest(
            method: "POST",
            path: "/r2/upload/complete",
            body: body
        )
        return try decoder.decode(UploadCompleteResponse.self, from: data)
    }

    func refreshPresignedURLs(
        uploadId: String,
        key: String,
        partNumbers: [Int]
    ) async throws -> [PresignedURL] {
        struct Body: Encodable {
            let uploadId: String
            let key: String
            let partNumbers: [Int]
        }

        struct Response: Decodable {
            let presignedUrls: [PresignedURL]
        }

        let body = Body(uploadId: uploadId, key: key, partNumbers: partNumbers)
        let (data, _) = try await makeRequest(
            method: "POST",
            path: "/r2/upload/refresh-urls",
            body: body
        )
        let response = try decoder.decode(Response.self, from: data)
        return response.presignedUrls
    }

    func abortUpload(uploadId: String, key: String, size: Int64) async throws {
        struct Body: Encodable {
            let uploadId: String
            let key: String
            let size: Int64
        }

        let body = Body(uploadId: uploadId, key: key, size: size)
        _ = try await makeRequest(method: "POST", path: "/r2/upload/abort", body: body)
    }

    // MARK: - Chunk Upload (Direct to R2)

    /// Upload a chunk directly to R2 via presigned URL.
    /// `nonisolated` because it only uses `chunkSession` which is immutable after init.
    /// This avoids serializing all concurrent chunk uploads through the actor's executor.
    nonisolated func uploadChunk(url: URL, data: Data) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let (_, response): (Data, URLResponse)
        do {
            (_, response) = try await chunkSession.data(for: request)
        } catch {
            throw KrevoAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KrevoAPIError.networkError("Invalid response from storage")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw KrevoAPIError.serverError(
                statusCode: httpResponse.statusCode,
                message: "Chunk upload failed"
            )
        }

        guard let etag = httpResponse.value(forHTTPHeaderField: "ETag") else {
            throw KrevoAPIError.serverError(
                statusCode: httpResponse.statusCode,
                message: "Missing ETag in chunk upload response"
            )
        }

        // Strip surrounding quotes from ETag and validate format
        let cleanEtag = etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        guard cleanEtag.count >= 16,
              cleanEtag.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else {
            throw KrevoAPIError.serverError(
                statusCode: httpResponse.statusCode,
                message: "Invalid ETag format in chunk upload response"
            )
        }
        return cleanEtag
    }

    // MARK: - Chunk Upload with Progress (Direct to R2)

    /// Upload a chunk directly to R2 via presigned URL, reporting byte-level progress.
    /// Uses a single shared delegate-based URLSession with a routing delegate.
    /// `nonisolated` to avoid serializing concurrent uploads through the actor.
    ///
    /// The shared session has a 60-second `timeoutIntervalForRequest` for stall
    /// detection — if no data flows for 60 seconds the session times out automatically,
    /// letting the retry loop in `ChunkUploader` handle the retry.
    /// Sendable box for sharing a URLSessionUploadTask reference with the cancellation handler.
    private final class UploadTaskBox: @unchecked Sendable {
        var task: URLSessionUploadTask?
    }

    nonisolated func uploadChunkWithProgress(
        url: URL,
        data: Data,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let box = UploadTaskBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = progressSession.uploadTask(with: request, from: data)
                box.task = task
                progressRouter.register(
                    taskIdentifier: task.taskIdentifier,
                    onProgress: onProgress,
                    continuation: continuation
                )
                task.resume()
            }
        } onCancel: {
            // Cancel the URLSessionTask so didCompleteWithError fires and cleans up the handler
            box.task?.cancel()
        }
    }

    // MARK: - Private Helpers

    private func makeRequest(
        method: String,
        path: String,
        body: (any Encodable)? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        let url = KrevoConstants.apiBaseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method

        if let token = deviceToken {
            request.setValue(token, forHTTPHeaderField: "X-Device-Token")
        }

        if let body {
            request.httpBody = try encoder.encode(body)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw KrevoAPIError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw KrevoAPIError.networkError("Invalid server response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw mapError(statusCode: httpResponse.statusCode, data: data, response: httpResponse)
        }

        return (data, httpResponse)
    }

    private func mapError(
        statusCode: Int,
        data: Data,
        response: HTTPURLResponse
    ) -> KrevoAPIError {
        // Try to parse structured error response
        struct ErrorResponse: Decodable {
            let error: String
            let code: String?
            let maxBytes: Int64?
        }

        let parsed = try? decoder.decode(ErrorResponse.self, from: data)
        let message = parsed?.error ?? "Unknown error"

        // Map by error code first
        if let code = parsed?.code {
            switch code {
            case "QUOTA_EXCEEDED":
                return .quotaExceeded
            case "FILE_TOO_LARGE":
                return .fileTooLarge(maxBytes: parsed?.maxBytes ?? 0)
            case "UPLOAD_EXPIRED":
                return .uploadExpired
            case "NO_SUBSCRIPTION":
                return .unauthorized
            default:
                break
            }
        }

        // Map by HTTP status
        switch statusCode {
        case 401:
            return .unauthorized
        case 429:
            let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
                .flatMap(Int.init) ?? 60
            return .rateLimited(retryAfter: retryAfter)
        default:
            return .serverError(statusCode: statusCode, message: message)
        }
    }
}

// MARK: - Chunk Progress Router

/// Shared URLSession delegate that routes progress and completion callbacks to per-task handlers.
/// A single instance is reused across all chunk uploads — avoids creating sessions per chunk.
///
/// Each in-flight upload registers its progress handler + continuation before creating the
/// URLSessionTask, and the router dispatches callbacks by `task.taskIdentifier`.
///
/// Marked `@unchecked Sendable` because:
/// - URLSession serializes delegate callbacks on its delegate queue
/// - `register` is called before `resume()`, so the entry exists by the time callbacks fire
/// - `unregister` is called in `didCompleteWithError`, which runs on the same serial queue
private final class ChunkProgressRouter: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {

    private struct TaskHandler {
        let onProgress: @Sendable (Int64) -> Void
        var httpResponse: HTTPURLResponse?
        var continuation: CheckedContinuation<String, Error>?
    }

    private let lock = NSLock()
    private var handlers: [Int: TaskHandler] = [:]

    func register(
        taskIdentifier: Int,
        onProgress: @Sendable @escaping (Int64) -> Void,
        continuation: CheckedContinuation<String, Error>
    ) {
        lock.lock()
        handlers[taskIdentifier] = TaskHandler(onProgress: onProgress, continuation: continuation)
        let count = handlers.count
        lock.unlock()

        if count > 500 {
            KrevoConstants.uploadLogger.warning("ChunkProgressRouter: \(count) handlers registered — possible leak")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        lock.lock()
        let handler = handlers[task.taskIdentifier]
        lock.unlock()
        handler?.onProgress(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse {
            lock.lock()
            handlers[dataTask.taskIdentifier]?.httpResponse = http
            lock.unlock()
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let id = task.taskIdentifier

        lock.lock()
        var handler = handlers.removeValue(forKey: id)
        lock.unlock()

        guard let cont = handler?.continuation else { return }
        handler?.continuation = nil

        if let error {
            cont.resume(throwing: KrevoAPIError.networkError(error.localizedDescription))
            return
        }

        guard let response = handler?.httpResponse else {
            cont.resume(throwing: KrevoAPIError.networkError("No response from storage"))
            return
        }

        guard (200...299).contains(response.statusCode) else {
            cont.resume(throwing: KrevoAPIError.serverError(
                statusCode: response.statusCode,
                message: "Chunk upload failed"
            ))
            return
        }

        let rawEtag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let etag = rawEtag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard etag.count >= 16,
              etag.allSatisfy({ $0.isHexDigit || $0 == "-" })
        else {
            cont.resume(throwing: KrevoAPIError.serverError(
                statusCode: response.statusCode,
                message: "Invalid ETag in chunk upload response"
            ))
            return
        }
        cont.resume(returning: etag)
    }
}
