import Foundation

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
}

// MARK: - API Client

actor KrevoAPIClient {
    private let session: URLSession
    /// Immutable after init — used only by `uploadChunk` which is `nonisolated`.
    /// `nonisolated(unsafe)` is safe here because URLSession is thread-safe and
    /// this property is never mutated after initialization.
    nonisolated(unsafe) private let chunkSession: URLSession
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

        // Strip surrounding quotes from ETag
        return etag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    // MARK: - Chunk Upload with Progress (Direct to R2)

    /// Upload a chunk directly to R2 via presigned URL, reporting byte-level progress.
    /// Uses a delegate-based URLSession to receive `didSendBodyData` callbacks.
    /// `nonisolated` to avoid serializing concurrent uploads through the actor.
    ///
    /// The per-request session uses a 60-second `timeoutIntervalForRequest` for stall
    /// detection — if no data flows for 60 seconds the session times out automatically,
    /// letting the retry loop in `ChunkUploader` handle the retry.
    nonisolated func uploadChunkWithProgress(
        url: URL,
        data: Data,
        onProgress: @Sendable @escaping (Int64) -> Void
    ) async throws -> String {
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")

        let delegate = ChunkUploadDelegate(onProgress: onProgress)

        // Per-request session with stall detection: 60s timeout if no data flows
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.waitsForConnectivity = true
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        defer { session.finishTasksAndInvalidate() }

        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            session.uploadTask(with: request, from: data).resume()
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

// MARK: - Chunk Upload Delegate

/// URLSession delegate for byte-level upload progress tracking.
/// Each instance is paired with a single upload task and bridges delegate
/// callbacks into async/await via `CheckedContinuation`.
///
/// Marked `@unchecked Sendable` because all mutation happens on the
/// URLSession delegate queue (serial) before the continuation fires.
private final class ChunkUploadDelegate: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate, @unchecked Sendable {
    let onProgress: @Sendable (Int64) -> Void
    var httpResponse: HTTPURLResponse?
    var continuation: CheckedContinuation<String, Error>?

    init(onProgress: @Sendable @escaping (Int64) -> Void) {
        self.onProgress = onProgress
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        onProgress(totalBytesSent)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        httpResponse = response as? HTTPURLResponse
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        if let error {
            continuation?.resume(throwing: KrevoAPIError.networkError(error.localizedDescription))
            continuation = nil
            return
        }

        guard let response = httpResponse else {
            continuation?.resume(throwing: KrevoAPIError.networkError("No response from storage"))
            continuation = nil
            return
        }

        guard (200...299).contains(response.statusCode) else {
            continuation?.resume(throwing: KrevoAPIError.serverError(
                statusCode: response.statusCode,
                message: "Chunk upload failed"
            ))
            continuation = nil
            return
        }

        let rawEtag = response.value(forHTTPHeaderField: "ETag") ?? ""
        let etag = rawEtag.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if etag.isEmpty {
            continuation?.resume(throwing: KrevoAPIError.serverError(
                statusCode: response.statusCode,
                message: "Missing ETag in chunk upload response"
            ))
        } else {
            continuation?.resume(returning: etag)
        }
        continuation = nil
    }
}
