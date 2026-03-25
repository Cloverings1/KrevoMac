import Foundation
import os

nonisolated enum KrevoConstants {
    static let baseURL = URL(string: "https://www.krevo.io")!
    static let apiBaseURL = URL(string: "https://www.krevo.io/api")!
    static let authURL = URL(string: "https://www.krevo.io/mac-auth")!
    static let urlScheme = "krevo"

    // Upload constants (match server-side graphite-uploader.ts)
    static let maxConcurrentChunks = 20
    static let maxMemoryBudget = 500_000_000 // 500 MB
    static let initialPresignedParts = 128
    static let urlRefreshBatchSize = 128
    static let maxRetries = 6
    static let retryBaseDelay: TimeInterval = 0.5
    static let retryMaxDelay: TimeInterval = 30.0
    static let chunkTimeout: TimeInterval = 600 // 10 minutes
    static let presignedURLExpiry: TimeInterval = 172_800 // 48 hours
    static let urlRefreshTimeout: TimeInterval = 45
    static let presignedURLSafetyMargin: TimeInterval = 300 // Evict URLs within 5 min of expiry

    // Keychain
    static let keychainService = "io.krevo.mac"
    static let keychainTokenKey = "device-token"

    // Upload queue
    static let maxConcurrentUploads = 3

    // Logging
    static let logger = Logger(subsystem: "io.krevo.mac", category: "general")
    static let uploadLogger = Logger(subsystem: "io.krevo.mac", category: "upload")
    static let authLogger = Logger(subsystem: "io.krevo.mac", category: "auth")
}
