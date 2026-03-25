import SwiftUI
import Network
import os

nonisolated enum GlobalBanner: Equatable {
    case networkOffline
    case authRequired
    case quotaIssue(String)
}

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
    var userName: String = ""

    // MARK: - Weather

    let weatherService = WeatherService()
    var weather: WeatherData?
    private var weatherRefreshTask: Task<Void, Never>?

    // MARK: - Network

    var isNetworkAvailable = true
    private var pathMonitor: NWPathMonitor?

    // MARK: - Uploads

    var uploadTasks: [UploadTask] = []
    var recentCompleted: [UploadTask] = []

    // Upload queue — limits simultaneous uploads to prevent resource exhaustion
    private var pendingQueue: [UploadTask] = []
    private var runningCount = 0
    private var isDraining = false

    // Cached for menu bar icon — avoids re-filtering on every SwiftUI pass
    var hasActiveUploads = false

    // Storage refresh debounce
    private var lastStorageRefresh: Date?
    private var storageLastRefreshed: Date?

    // Completion banner
    var showCompletionBanner = false
    var completedFileName = ""
    private var bannerDismissTask: Task<Void, Never>?
    private var bannerGeneration: UInt64 = 0

    // Global messaging
    var globalBanner: GlobalBanner?

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
        startWeatherRefresh()
    }

    private func startWeatherRefresh() {
        weatherRefreshTask = Task {
            while !Task.isCancelled {
                await refreshWeather()
                try? await Task.sleep(for: .seconds(900)) // 15 minutes
            }
        }
    }

    func refreshWeather() async {
        if let data = try? await weatherService.fetch() {
            weather = data
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                let isAvailable = path.status == .satisfied
                KrevoConstants.logger.info("Network status changed: \(isAvailable ? "online" : "offline")")
                self?.isNetworkAvailable = isAvailable

                if isAvailable {
                    if case .networkOffline = self?.globalBanner {
                        self?.globalBanner = nil
                    }
                } else {
                    self?.globalBanner = .networkOffline
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.krevo.mac.network"))
    }

    // MARK: - Computed

    var activeUploads: [UploadTask] { uploadTasks.filter { $0.state.isActive } }

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
            if case .authRequired = globalBanner {
                globalBanner = nil
            }
        } catch {
            // Token is invalid or expired — clear it
            isAuthenticated = false
            await apiClient.clearToken()
            KeychainService.deleteToken()
            globalBanner = .authRequired
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
        await abortAllUploads()

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
        storageLastRefreshed = nil
        tier = ""
        plan = ""
        userName = ""
        weather = nil
        weatherRefreshTask?.cancel()
        weatherRefreshTask = nil
        uploadTasks.removeAll()
        recentCompleted.removeAll()
        pendingQueue.removeAll()
        runningCount = 0
        hasActiveUploads = false
        showCompletionBanner = false
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        globalBanner = nil
    }

    // MARK: - Storage

    func refreshStorage() async {
        do {
            let info = try await apiClient.getStorageInfo()
            applyStorageInfo(info)
            storageLastRefreshed = Date()
        } catch {
            KrevoConstants.logger.error("Storage refresh failed: \(error.localizedDescription)")

            // Single retry after 2s
            do {
                try await Task.sleep(for: .seconds(2))
                let info = try await apiClient.getStorageInfo()
                applyStorageInfo(info)
                storageLastRefreshed = Date()
            } catch {
                KrevoConstants.logger.error("Storage refresh retry failed: \(error.localizedDescription)")
            }
        }
    }

    var isStorageStale: Bool {
        guard let lastRefresh = storageLastRefreshed else { return true }
        return Date().timeIntervalSince(lastRefresh) > 300 // 5 minutes
    }

    // MARK: - Uploads

    func startUpload(urls: [URL]) {
        if isStorageStale {
            KrevoConstants.logger.warning("Storage info is stale — quota check may be inaccurate")
        }

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
                globalBanner = .quotaIssue("A file exceeds your current plan's file size limit.")
                continue
            }
            let remaining = storageLimit - storageUsed
            if storageLimit > 0, task.fileSize > remaining {
                task.state = .failed("Not enough storage space. Upgrade your plan for more space.")
                globalBanner = .quotaIssue("You do not have enough available storage for this upload.")
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
        task.resetForRetry()

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
        hasActiveUploads = false
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

    static func formatTimeAgo(_ date: Date, now: Date = Date()) -> String {
        let interval = now.timeIntervalSince(date)
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
        userName = info.name ?? ""
        storageLoaded = true
    }

    /// Drain the pending queue, launching uploads up to the concurrency limit.
    private func drainQueue() {
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }

        while runningCount < KrevoConstants.maxConcurrentUploads,
              let task = pendingQueue.first {
            pendingQueue.removeFirst()
            runningCount += 1
            hasActiveUploads = true

            Task {
                await uploadEngine.uploadFile(task: task)
                handleUploadCompletion(task)
                runningCount -= 1
                hasActiveUploads = runningCount > 0 || !pendingQueue.isEmpty
                drainQueue()
            }
        }
    }

    private func handleUploadCompletion(_ task: UploadTask) {
        if case .completed = task.state {
            KrevoConstants.uploadLogger.info("Upload completed: \(task.fileName) (\(AppState.formatBytes(task.fileSize)))")
            // Add to recent, keep last 5
            recentCompleted.insert(task, at: 0)
            if recentCompleted.count > 5 {
                recentCompleted.removeLast()
            }

            // Show completion banner with filename
            bannerGeneration &+= 1
            let currentGeneration = bannerGeneration
            completedFileName = task.fileName
            bannerDismissTask?.cancel()
            showCompletionBanner = true
            bannerDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                // Only dismiss if no newer banner has appeared
                if bannerGeneration == currentGeneration {
                    showCompletionBanner = false
                }
            }

            // Haptic feedback for that "incredible feel"
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

            // Debounced storage refresh — only fires once even if multiple uploads complete
            // within the same 1-second window
            let now = Date()
            if lastStorageRefresh == nil || now.timeIntervalSince(lastStorageRefresh!) > 1.0 {
                lastStorageRefresh = now
                Task { await refreshStorage() }
            }

            // Auto-prune terminal tasks older than 5 minutes
            let cutoff = now.addingTimeInterval(-300)
            uploadTasks.removeAll { $0.state.isTerminal && ($0.completionTime ?? .distantPast) < cutoff }
        }
    }
}
