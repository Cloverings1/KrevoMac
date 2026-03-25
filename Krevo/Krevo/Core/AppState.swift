import SwiftUI
import Network
import os

@Observable
final class AppState {

    // Shared singleton so AppDelegate can always reach it (even before the popover opens)
    @MainActor static let shared = AppState()

    // MARK: - Auth

    var isAuthenticated = false
    var isCheckingAuth = true
    private var hasInitialized = false

    // MARK: - Storage

    var storageUsed: Int64 = 0
    var storageLimit: Int64 = 0
    var maxFileSize: Int64 = 0
    var tier: String = ""
    var plan: String = ""
    var storageLoaded = false

    // MARK: - Network

    var isNetworkAvailable = true
    private var pathMonitor: NWPathMonitor?

    // MARK: - Uploads

    var uploadTasks: [UploadTask] = []
    var recentCompleted: [UploadTask] = []

    // Upload queue — limits simultaneous uploads to prevent resource exhaustion
    private var pendingQueue: [UploadTask] = []
    private var runningCount = 0

    // MARK: - Services

    let apiClient = KrevoAPIClient()
    let uploadEngine: UploadEngine

    // MARK: - Init

    private init() {
        self.uploadEngine = UploadEngine(apiClient: apiClient)
    }

    /// Run once at app startup. Safe to call multiple times — only the first call performs work.
    func initialize() async {
        guard !hasInitialized else { return }
        hasInitialized = true
        startNetworkMonitor()
        await checkAuth()
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.isNetworkAvailable = path.status == .satisfied
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.krevo.mac.network"))
    }

    // MARK: - Computed

    var activeUploads: [UploadTask] { uploadTasks.filter { $0.state.isActive } }
    var hasActiveUploads: Bool { !activeUploads.isEmpty }

    var storagePercent: Double {
        guard storageLimit > 0 else { return 0 }
        return Double(storageUsed) / Double(storageLimit)
    }

    // MARK: - Auth Actions

    func checkAuth() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }

        guard let token = KeychainService.loadToken() else {
            isAuthenticated = false
            return
        }

        await apiClient.setToken(token)

        do {
            let info = try await apiClient.validateToken()
            applyStorageInfo(info)
            isAuthenticated = true
        } catch {
            // Token is invalid or expired — clear it
            isAuthenticated = false
            await apiClient.clearToken()
            KeychainService.deleteToken()
        }
    }

    func signIn(token: String) async {
        do {
            try KeychainService.save(token: token)
        } catch {
            KrevoConstants.authLogger.error("Keychain save failed: \(error.localizedDescription)")
            // Surface the error so the user knows sign-in didn't persist
            isAuthenticated = false
            isCheckingAuth = false
            return
        }
        await apiClient.setToken(token)
        await checkAuth()
    }

    func signOut() async {
        // Attempt to revoke on the server (best-effort)
        try? await apiClient.revokeToken()

        // Clear local state regardless
        await apiClient.clearToken()
        KeychainService.deleteToken()

        isAuthenticated = false
        storageUsed = 0
        storageLimit = 0
        maxFileSize = 0
        storageLoaded = false
        tier = ""
        plan = ""
        uploadTasks.removeAll()
        recentCompleted.removeAll()
        pendingQueue.removeAll()
        runningCount = 0
    }

    // MARK: - Storage

    func refreshStorage() async {
        do {
            let info = try await apiClient.getStorageInfo()
            applyStorageInfo(info)
        } catch {
            // Silent failure — storage meter keeps last known values
        }
    }

    // MARK: - Uploads

    func startUpload(urls: [URL]) {
        for url in urls {
            let task: UploadTask

            do {
                task = try UploadTask(fileURL: url)
            } catch {
                let failed = UploadTask(failedURL: url, message: "Could not read file: \(error.localizedDescription)")
                uploadTasks.insert(failed, at: 0)
                continue
            }

            uploadTasks.insert(task, at: 0)

            // Pre-flight: file size checks against plan limits
            if maxFileSize > 0, task.fileSize > maxFileSize {
                let limit = AppState.formatBytes(maxFileSize)
                task.state = .failed("File exceeds the \(limit) limit for your plan.")
                continue
            }
            let remaining = storageLimit - storageUsed
            if storageLimit > 0, task.fileSize > remaining {
                task.state = .failed("Not enough storage space. Upgrade your plan for more space.")
                continue
            }

            pendingQueue.append(task)
        }

        drainQueue()
    }

    func cancelUpload(_ task: UploadTask) {
        Task {
            await uploadEngine.cancelUpload(
                taskId: task.id,
                uploadId: task.uploadId,
                key: task.uploadKey,
                size: task.fileSize
            )
        }
    }

    func retryUpload(_ task: UploadTask) {
        // Reset the task state and re-enqueue through the queue
        task.state = .pending
        task.progress = 0
        task.uploadedBytes = 0
        task.speed = 0
        task.estimatedTimeRemaining = nil
        task.completedChunks = 0
        task.totalChunks = 0

        pendingQueue.append(task)
        drainQueue()
    }

    func clearCompleted() {
        uploadTasks.removeAll { $0.state.isTerminal }
    }

    /// Abort all active uploads — used on app termination.
    func abortAllUploads() async {
        let active = activeUploads
        for task in active {
            await uploadEngine.cancelUpload(
                taskId: task.id,
                uploadId: task.uploadId,
                key: task.uploadKey,
                size: task.fileSize
            )
        }
    }

    // MARK: - Formatting

    static func formatBytes(_ bytes: Int64) -> String {
        let absBytes = abs(bytes)
        switch absBytes {
        case 0..<1_000:
            return "\(absBytes) B"
        case 1_000..<1_000_000:
            return String(format: "%.0f KB", Double(absBytes) / 1_000)
        case 1_000_000..<1_000_000_000:
            return String(format: "%.1f MB", Double(absBytes) / 1_000_000)
        case 1_000_000_000..<1_000_000_000_000:
            let gb = Double(absBytes) / 1_000_000_000
            if gb >= 100 {
                return String(format: "%.0f GB", gb)
            }
            return String(format: "%.1f GB", gb)
        default:
            return String(format: "%.2f TB", Double(absBytes) / 1_000_000_000_000)
        }
    }

    static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1_000 {
            return "\(Int(bytesPerSecond)) B/s"
        } else if bytesPerSecond < 1_000_000 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
        } else if bytesPerSecond < 1_000_000_000 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1_000_000)
        } else {
            return String(format: "%.2f GB/s", bytesPerSecond / 1_000_000_000)
        }
    }

    static func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "finishing" }
        if seconds < 60 { return "\(Int(seconds))s remaining" }
        if seconds < 3600 {
            let mins = Int(seconds) / 60
            let secs = Int(seconds) % 60
            return secs > 0 ? "\(mins)m \(secs)s remaining" : "\(mins)m remaining"
        }
        let hrs = Int(seconds) / 3600
        let mins = (Int(seconds) % 3600) / 60
        return "\(hrs)h \(mins)m remaining"
    }

    static func formatTimeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60)) min ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Private

    private func applyStorageInfo(_ info: StorageInfo) {
        storageUsed = info.used
        storageLimit = info.limit
        maxFileSize = info.maxFileSize
        tier = info.tier
        plan = info.plan
        storageLoaded = true
    }

    /// Drain the pending queue, launching uploads up to the concurrency limit.
    private func drainQueue() {
        while runningCount < KrevoConstants.maxConcurrentUploads,
              let task = pendingQueue.first {
            pendingQueue.removeFirst()
            runningCount += 1

            Task {
                await uploadEngine.uploadFile(task: task)
                handleUploadCompletion(task)
                runningCount -= 1
                drainQueue()
            }
        }
    }

    private func handleUploadCompletion(_ task: UploadTask) {
        if case .completed = task.state {
            // Add to recent, keep last 5
            recentCompleted.insert(task, at: 0)
            if recentCompleted.count > 5 {
                recentCompleted.removeLast()
            }

            // Refresh storage after successful upload
            Task { await refreshStorage() }
        }
    }
}
