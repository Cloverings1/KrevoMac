import Foundation
import os

nonisolated enum KrevoConstants {
    static let baseURL = URL(string: "https://www.krevo.io")!
    static let apiBaseURL = URL(string: "https://www.krevo.io/api")!
    static let authURL = URL(string: "https://www.krevo.io/mac-auth")!
    static let urlScheme = "krevo"

    // Upload constants (match server-side graphite-uploader.ts).
    // Tuned for multi-gigabit links: enough parallel PUTs and RAM to fill the pipe without
    // starving URLSession (see maxConcurrentChunkHTTPConnections).
    static let maxConcurrentChunks = 32
    static let minConcurrentChunks = 4
    static let concurrencyScaleWindow = 12
    static let concurrencyScaleUpFailureRate = 0.08
    static let concurrencyScaleDownFailureRate = 0.28
    /// Below this average chunk latency, adaptive concurrency ramps up (aggressive on fast networks).
    static let targetChunkLatencySeconds: TimeInterval = 0.85
    static let chunkFailureLatencyPenaltySeconds: TimeInterval = 2.8
    /// Global cap for in-flight chunk *reservations* (multiple uploads share this pool).
    static let maxMemoryBudget = 1_500_000_000 // 1.5 GB
    static let initialPresignedParts = 128
    static let urlRefreshBatchSize = 128
    static let maxRetries = 6
    static let retryBaseDelay: TimeInterval = 0.5
    static let retryMaxDelay: TimeInterval = 30.0
    static let chunkTimeout: TimeInterval = 60
    static let presignedURLExpiry: TimeInterval = 172_800 // 48 hours
    static let urlRefreshTimeout: TimeInterval = 45
    static let presignedURLSafetyMargin: TimeInterval = 300 // Evict URLs within 5 min of expiry

    // Keychain
    static let keychainService = "io.krevo.mac"
    static let keychainTokenKey = "device-token"

    // Upload queue — parallel files (each file also runs up to maxConcurrentChunks chunk PUTs).
    static let maxConcurrentUploads = 8

    /// URLSession limit per storage host: must cover worst case (all files × chunks) or connections queue.
    static var maxConcurrentChunkHTTPConnections: Int {
        max(maxConcurrentChunks * maxConcurrentUploads, maxConcurrentChunks + 8)
    }

    // History
    static let maxHistoryCount = 50

    // Logging
    static let logger = Logger(subsystem: "io.krevo.mac", category: "general")
    static let uploadLogger = Logger(subsystem: "io.krevo.mac", category: "upload")
    static let authLogger = Logger(subsystem: "io.krevo.mac", category: "auth")
}
