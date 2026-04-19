import SwiftUI
import Network
import os
import UserNotifications

nonisolated enum GlobalBanner: Equatable {
    case networkOffline
    case authRequired
    case quotaIssue(String)
    case serverAnnouncement(String)
}

nonisolated enum AccountAccessState: Equatable {
    case unknown
    case fullAccess
    case readOnly(AccountReadOnlyReason)
}

nonisolated enum AccountReadOnlyReason: String, Equatable {
    case free
    case unpaid
    case upgradeRequired

    var title: String {
        switch self {
        case .free:
            return "Free plan"
        case .unpaid:
            return "Billing issue"
        case .upgradeRequired:
            return "Upgrade required"
        }
    }

    var message: String {
        switch self {
        case .free:
            return "This account is connected in read-only mode. Upgrade on the web to upload from Mac."
        case .unpaid:
            return "Billing needs attention before uploads can resume. Manage the account on the web."
        case .upgradeRequired:
            return "Uploads are locked until this account is upgraded. Manage the account on the web."
        }
    }

    var statusText: String {
        switch self {
        case .free:
            return "Read-only free plan"
        case .unpaid:
            return "Read-only until billing is fixed"
        case .upgradeRequired:
            return "Read-only until upgraded"
        }
    }
}

@Observable
final class AppState {

    // Shared singleton so AppDelegate can always reach it (even before the popover opens)
    @MainActor static let shared = AppState()

    // MARK: - Auth

    var isAuthenticated = false
    var isCheckingAuth = true
    var hasStoredSession = false
    var isSessionValidated = false
    var authMessage: String?
    private var hasInitialized = false
    private var storedDeviceToken: String?

    // MARK: - Storage

    var storageUsed: Int64 = 0
    var storageLimit: Int64 = 0
    var maxFileSize: Int64 = 0
    var tier: String = ""
    var plan: String = ""
    var storageLoaded = false
    var storageErrorMessage: String?
    var userName: String = ""
    var userEmail: String = ""
    var accountCanUpload = true
    var serverAccountStateRaw: String = ""
    var serverUpgradeMessage: String?

    // MARK: - Network

    var isNetworkAvailable = true
    private var pathMonitor: NWPathMonitor?
    private var reconnectTask: Task<Void, Never>?

    // MARK: - Uploads

    var uploadTasks: [UploadTask] = []
    var recentCompleted: [UploadTask] = []

    // Upload queue — limits simultaneous uploads to prevent resource exhaustion
    private var pendingQueue: [UploadTask] = []
    private var runningCount = 0
    private var isDraining = false

    var hasActiveUploads: Bool { !activeUploads.isEmpty }

    // Storage refresh debounce
    private var storageRefreshDebounceTime: Date?
    private var storageLastRefreshed: Date?

    // Completion banner
    var showCompletionBanner = false
    var completedFileName = ""
    var completedShareURL: String?
    private var bannerDismissTask: Task<Void, Never>?
    private var bannerGeneration: UInt64 = 0

    // Global messaging
    var globalBanner: GlobalBanner?

    // MARK: - Services

    let apiClient = KrevoAPIClient()
    let uploadEngine: UploadEngine
    let historyStore = UploadHistoryStore()

    // MARK: - Init

    private init() {
        self.uploadEngine = UploadEngine(apiClient: apiClient)
    }

    /// Run once at app startup. Safe to call multiple times — only the first call performs work.
    func initialize() async {
        guard !hasInitialized else { return }
        hasInitialized = true
        startNetworkMonitor()
        let entries = await historyStore.load()
        recentCompleted = entries.compactMap { entry in
            guard entry.result == .completed else { return nil }
            return UploadTask(historyEntry: entry)
        }
        uploadTasks = entries.compactMap { entry in
            guard entry.result != .completed else { return nil }
            return UploadTask(historyEntry: entry)
        }
        await checkAuth()
        await checkServerStatus()
    }

    /// Check for server-driven announcements (best-effort, silent on failure).
    private func checkServerStatus() async {
        do {
            let status = try await apiClient.getClientStatus()
            if let message = status.message, !message.isEmpty {
                globalBanner = .serverAnnouncement(message)
            } else if case .serverAnnouncement = globalBanner {
                globalBanner = nil // Clear stale announcement
            }
        } catch {
            // Silent — server may not have this endpoint yet
        }
    }

    private func startNetworkMonitor() {
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let isAvailable = path.status == .satisfied
                let wasAvailable = self.isNetworkAvailable
                KrevoConstants.logger.info("Network status changed: \(isAvailable ? "online" : "offline")")
                self.isNetworkAvailable = isAvailable

                if isAvailable {
                    if case .networkOffline = self.globalBanner {
                        self.globalBanner = nil
                    }
                    if !wasAvailable {
                        self.scheduleReconnect(reason: "network restored")
                    }
                } else {
                    self.globalBanner = .networkOffline
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "io.krevo.mac.network"))
    }

    func applicationDidBecomeActive() async {
        guard shouldPresentAuthenticatedShell else { return }
        guard isNetworkAvailable else { return }
        guard !isCheckingAuth else { return }

        if !isSessionValidated || storageErrorMessage != nil || authMessage != nil {
            scheduleReconnect(reason: "app activated")
        }
    }

    func handleBlockedUploadAttempt() {
        if !isNetworkAvailable {
            globalBanner = .networkOffline
        }
        storageErrorMessage = uploadAvailabilityMessage
    }

    // MARK: - Computed

    var activeUploads: [UploadTask] { uploadTasks.filter { $0.state.isActive } }
    var reservedUploadBytes: Int64 {
        uploadTasks.reduce(into: 0) { partial, task in
            guard !task.state.isTerminal else { return }
            partial += task.fileSize
        }
    }

    var storagePercent: Double {
        guard storageLimit > 0 else { return 0 }
        return Double(storageUsed) / Double(storageLimit)
    }

    var remainingStorage: Int64 {
        max(0, storageLimit - storageUsed - reservedUploadBytes)
    }

    var accountDisplayName: String {
        if !userName.isEmpty { return userName }
        if !userEmail.isEmpty { return userEmail }
        return "Your account"
    }

    var shouldPresentAuthenticatedShell: Bool {
        isAuthenticated || hasStoredSession
    }

    var accountAccessState: AccountAccessState {
        guard storageLoaded else { return .unknown }

        let normalizedPlan = normalizedAccountStateValue(plan)
        let normalizedTier = normalizedAccountStateValue(tier)
        let normalizedServerState = normalizedAccountStateValue(serverAccountStateRaw)
        let values = [normalizedPlan, normalizedTier, normalizedServerState]

        if values.contains(where: { $0.contains("unpaid") || $0.contains("past_due") || $0.contains("past due") }) {
            return .readOnly(.unpaid)
        }

        if values.contains(where: { $0 == "free" || $0.contains("free_plan") || $0.contains("free plan") }) ||
            normalizedTier == "free"
        {
            return .readOnly(.free)
        }

        if !accountCanUpload ||
            values.contains(where: { $0.contains("upgrade_required") || $0.contains("upgrade required") })
        {
            return .readOnly(.upgradeRequired)
        }

        return .fullAccess
    }

    var isReadOnlyAccount: Bool {
        if case .readOnly = accountAccessState {
            return true
        }
        return false
    }

    var accountPlanLabel: String {
        if storageLoaded {
            let base = tier.trimmingCharacters(in: .whitespacesAndNewlines)
            if !base.isEmpty {
                return base
                    .replacingOccurrences(of: "_", with: " ")
                    .localizedCapitalized
            }

            if case .readOnly(.free) = accountAccessState {
                return "Free"
            }
        }

        return storageLoaded ? "Unknown" : "Unavailable"
    }

    var canStartUploads: Bool {
        guard shouldPresentAuthenticatedShell else { return false }
        guard isSessionValidated else { return false }
        guard isNetworkAvailable else { return false }
        return !isReadOnlyAccount
    }

    var uploadAvailabilityMessage: String {
        guard shouldPresentAuthenticatedShell else {
            return "Connect your account before starting uploads."
        }

        if !isNetworkAvailable {
            return "Reconnect to start uploads."
        }

        if !isSessionValidated {
            return "Reconnect to validate your session before starting uploads."
        }

        if case .readOnly(let reason) = accountAccessState {
            return serverUpgradeMessage ?? reason.message
        }

        return "Uploads are temporarily unavailable."
    }

    // MARK: - Auth Actions

    func checkAuth() async {
        isCheckingAuth = true
        defer { isCheckingAuth = false }

        let token = storedDeviceToken ?? KeychainService.loadToken()
        guard let token else {
            storedDeviceToken = nil
            clearLocalSession(preserveAuthMessage: false)
            return
        }

        storedDeviceToken = token
        hasStoredSession = true
        await apiClient.setToken(token)

        do {
            let info = try await apiClient.validateToken()
            applyStorageInfo(info)
            isAuthenticated = true
            isSessionValidated = true
            authMessage = nil
            storageErrorMessage = nil
            if case .authRequired = globalBanner {
                globalBanner = nil
            }
        } catch let apiError as KrevoAPIError {
            switch apiError {
            case .unauthorized:
                await expireStoredSession(message: "Your saved session expired. Connect your account again.")
            default:
                preserveAuthenticatedShell(for: apiError)
            }
        } catch {
            preserveAuthenticatedShell(for: error)
        }
    }

    func signIn(token: String) async {
        authMessage = nil
        do {
            try KeychainService.save(token: token)
        } catch {
            KrevoConstants.authLogger.error("Keychain save failed: \(error.localizedDescription)")
            isAuthenticated = false
            hasStoredSession = false
            authMessage = "Could not save your session locally. Check Keychain access and retry."
            return
        }
        storedDeviceToken = token
        userName = ""
        userEmail = ""
        storageErrorMessage = nil
        accountCanUpload = true
        serverAccountStateRaw = ""
        serverUpgradeMessage = nil
        await apiClient.setToken(token)
        await checkAuth()
    }

    func signOut() async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await abortAllUploads()
        let token = storedDeviceToken ?? KeychainService.loadToken()
        storedDeviceToken = nil

        clearLocalSession(preserveAuthMessage: false)
        Task { await historyStore.clear() }
        await apiClient.clearToken()
        KeychainService.deleteToken()

        guard let token else { return }
        Task {
            let revocationClient = KrevoAPIClient()
            await revocationClient.setToken(token)
            try? await revocationClient.revokeToken()
        }
    }

    // MARK: - Completion banner

    /// Present the completion/share banner. Uses a generation token so that
    /// rapidly-repeated presentations cancel each other cleanly — the latest
    /// caller wins and only its dismissal actually hides the banner.
    func presentCompletionBanner(fileName: String, shareURL: String?, duration: TimeInterval = 3) {
        bannerGeneration &+= 1
        let generation = bannerGeneration
        completedFileName = fileName
        completedShareURL = shareURL
        bannerDismissTask?.cancel()
        showCompletionBanner = true
        bannerDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.bannerGeneration == generation else { return }
            self.showCompletionBanner = false
        }
    }

    // MARK: - Storage

    @discardableResult
    func refreshStorage() async -> Bool {
        do {
            let info = try await apiClient.getStorageInfo()
            applyStorageInfo(info)
            isSessionValidated = true
            authMessage = nil
            storageLastRefreshed = Date()
            storageErrorMessage = nil
        } catch {
            KrevoConstants.logger.error("Storage refresh failed: \(error.localizedDescription)")

            // Single retry after 2s
            do {
                try await Task.sleep(for: .seconds(2))
                let info = try await apiClient.getStorageInfo()
                applyStorageInfo(info)
                isSessionValidated = true
                authMessage = nil
                storageLastRefreshed = Date()
                storageErrorMessage = nil
            } catch let apiError as KrevoAPIError {
                KrevoConstants.logger.error("Storage refresh retry failed: \(apiError.localizedDescription)")
                if case .unauthorized = apiError {
                    await expireStoredSession(message: "Your saved session expired. Connect your account again.")
                    return false
                }
                storageErrorMessage = storageFailureMessage(for: apiError)
                scheduleReconnect(reason: "storage refresh failed")
                await checkServerStatus()
                return false
            } catch {
                KrevoConstants.logger.error("Storage refresh retry failed: \(error.localizedDescription)")
                storageErrorMessage = storageFailureMessage(for: error)
                scheduleReconnect(reason: "storage refresh failed")
                await checkServerStatus()
                return false
            }
        }

        // Piggyback: check for server announcements
        await checkServerStatus()
        return true
    }

    var isStorageStale: Bool {
        guard let lastRefresh = storageLastRefreshed else { return true }
        return Date().timeIntervalSince(lastRefresh) > 300 // 5 minutes
    }

    // MARK: - Uploads

    func startUpload(urls: [URL]) {
        guard !urls.isEmpty else { return }

        Task { @MainActor in
            guard canStartUploads else {
                handleBlockedUploadAttempt()
                return
            }

            if isStorageStale {
                KrevoConstants.logger.warning("Storage info is stale — refreshing before preflight")
                let refreshed = await refreshStorage()
                guard refreshed, canStartUploads else {
                    handleBlockedUploadAttempt()
                    return
                }
            }

            let expanded = expandURLs(urls)
            var remaining = storageLimit > 0 ? max(0, storageLimit - storageUsed - reservedUploadBytes) : Int64.max

            for file in expanded {
                let task: UploadTask

                do {
                    task = try UploadTask(fileURL: file.url, relativePath: file.relativePath)
                } catch {
                    let failed = UploadTask(
                        failedURL: file.url,
                        message: "Could not read file: \(error.localizedDescription)",
                        relativePath: file.relativePath
                    )
                    uploadTasks.insert(failed, at: 0)
                    continue
                }

                if maxFileSize > 0, task.fileSize > maxFileSize {
                    let limit = AppState.formatBytes(maxFileSize)
                    task.state = .failed("File exceeds the \(limit) limit for your plan.")
                    globalBanner = .quotaIssue("A file exceeds your current plan's file size limit.")
                    uploadTasks.insert(task, at: 0)
                    continue
                }

                if storageLimit > 0, task.fileSize > remaining {
                    task.state = .failed("Not enough storage space. Upgrade your plan for more space.")
                    globalBanner = .quotaIssue("You do not have enough available storage for this upload.")
                    uploadTasks.insert(task, at: 0)
                    continue
                }

                uploadTasks.insert(task, at: 0)
                pendingQueue.append(task)
                if storageLimit > 0 {
                    remaining = max(0, remaining - task.fileSize)
                }
            }

            drainQueue()
        }
    }

    func cancelUpload(_ task: UploadTask) {
        if let pendingIndex = pendingQueue.firstIndex(where: { $0.id == task.id }) {
            pendingQueue.remove(at: pendingIndex)
            task.markCancelled()
            handleUploadCompletion(task)
            return
        }

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
        let clearedIssueIDs = Set(uploadTasks.compactMap { task -> UUID? in
            switch task.state {
            case .failed, .cancelled:
                return task.id
            default:
                return nil
            }
        })

        uploadTasks.removeAll { $0.state.isTerminal }

        if !clearedIssueIDs.isEmpty {
            Task { await historyStore.remove(ids: clearedIssueIDs) }
        }
    }

    func deleteHistoryTask(_ task: UploadTask) {
        guard task.state.isTerminal else { return }

        recentCompleted.removeAll { $0.id == task.id }
        uploadTasks.removeAll { $0.id == task.id && $0.state.isTerminal }

        Task { await historyStore.remove(ids: [task.id]) }
    }

    func requestShareURL(for task: UploadTask) async -> String? {
        if let shareURL = task.shareURL, !shareURL.isEmpty {
            return shareURL
        }

        guard let fileId = completedFileId(for: task) else { return nil }

        do {
            let link = try await apiClient.createShareLink(fileId: fileId)
            task.shareURL = link.url
            await historyStore.updateShareURL(id: task.id, shareURL: link.url)
            return link.url
        } catch {
            KrevoConstants.uploadLogger.error("Failed to generate share link for \(task.fileName): \(error.localizedDescription)")
            return nil
        }
    }

    private func completedFileId(for task: UploadTask) -> String? {
        guard case .completed(let fileId) = task.state else { return nil }
        return fileId
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
        accountCanUpload = info.canUpload
        serverAccountStateRaw = info.accountState ?? ""
        serverUpgradeMessage = info.upgradeMessage
        if let userName = Self.normalizedProfileValue(info.name) {
            self.userName = userName
        }
        if let userEmail = Self.normalizedProfileValue(info.email) {
            self.userEmail = userEmail
        }
        storageLoaded = true
    }

    private func preserveAuthenticatedShell(for error: Error) {
        hasStoredSession = true
        isAuthenticated = true
        isSessionValidated = false
        authMessage = authFailureMessage(for: error)
        storageErrorMessage = storageFailureMessage(for: error)
        if case .authRequired = globalBanner {
            globalBanner = nil
        }
        if isNetworkAvailable {
            scheduleReconnect(reason: "session validation failed")
        }
    }

    private func storageFailureMessage(for error: Error) -> String {
        guard let apiError = error as? KrevoAPIError else {
            return isNetworkAvailable
                ? "Storage info is temporarily unavailable."
                : "Reconnect to reload storage details."
        }

        switch apiError {
        case .networkError:
            return "Reconnect to reload storage details."
        case .rateLimited:
            return "Storage info is temporarily unavailable."
        case .serverError:
            return "Storage info is temporarily unavailable."
        default:
            return "Storage info is temporarily unavailable."
        }
    }

    private func scheduleReconnect(reason: String) {
        guard shouldPresentAuthenticatedShell else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            KrevoConstants.logger.info("Scheduling reconnect attempt: \(reason)")
            try? await Task.sleep(for: .milliseconds(350))
            guard self.isNetworkAvailable else { return }
            guard self.shouldPresentAuthenticatedShell else { return }
            await self.checkAuth()
        }
    }

    private func clearLocalSession(preserveAuthMessage: Bool) {
        isAuthenticated = false
        isSessionValidated = false
        hasStoredSession = false
        storedDeviceToken = nil
        storageUsed = 0
        storageLimit = 0
        maxFileSize = 0
        storageLoaded = false
        storageLastRefreshed = nil
        tier = ""
        plan = ""
        userName = ""
        userEmail = ""
        accountCanUpload = true
        serverAccountStateRaw = ""
        serverUpgradeMessage = nil
        storageErrorMessage = nil
        if !preserveAuthMessage {
            authMessage = nil
        }
        uploadTasks.removeAll()
        recentCompleted.removeAll()
        pendingQueue.removeAll()
        runningCount = 0
        showCompletionBanner = false
        bannerDismissTask?.cancel()
        bannerDismissTask = nil
        globalBanner = nil
    }

    private func expireStoredSession(message: String) async {
        reconnectTask?.cancel()
        reconnectTask = nil
        await apiClient.clearToken()
        KeychainService.deleteToken()
        clearLocalSession(preserveAuthMessage: true)
        authMessage = message
        globalBanner = .authRequired
    }

    private static func normalizedProfileValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedAccountStateValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
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

            Task {
                await uploadEngine.uploadFile(task: task)
                handleUploadCompletion(task)
                runningCount -= 1
                drainQueue()
            }
        }
    }

    private func handleUploadCompletion(_ task: UploadTask) {
        guard task.state.isTerminal else { return }

        switch task.state {
        case .completed:
            KrevoConstants.uploadLogger.info("Upload completed: \(task.fileName) (\(AppState.formatBytes(task.fileSize)))")
            recentCompleted.removeAll { $0.id == task.id }
            recentCompleted.insert(task, at: 0)
            if recentCompleted.count > KrevoConstants.maxHistoryCount {
                recentCompleted = Array(recentCompleted.prefix(KrevoConstants.maxHistoryCount))
            }

            presentCompletionBanner(fileName: task.fileName, shareURL: task.shareURL, duration: 3)

            // Haptic feedback for that "incredible feel"
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

            // System notification (no sound)
            let content = UNMutableNotificationContent()
            content.title = "Upload complete"
            content.body = "\(task.fileName) - \(AppState.formatBytes(task.fileSize))"
            let notifRequest = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            Task { try? await UNUserNotificationCenter.current().add(notifRequest) }
        case .failed(let message):
            KrevoConstants.uploadLogger.error("Upload failed: \(task.fileName) - \(message)")
        case .cancelled:
            KrevoConstants.uploadLogger.info("Upload cancelled: \(task.fileName)")
        default:
            break
        }

        if let entry = historyEntry(for: task) {
            Task { await historyStore.append(entry) }
        }

        let now = Date()
        if storageRefreshDebounceTime == nil || now.timeIntervalSince(storageRefreshDebounceTime!) > 1.0 {
            storageRefreshDebounceTime = now
            Task { await refreshStorage() }
        }

        let cutoff = now.addingTimeInterval(-300)
        uploadTasks.removeAll { $0.state.isTerminal && ($0.completionTime ?? .distantPast) < cutoff }
    }

    private func authFailureMessage(for error: Error) -> String {
        guard let apiError = error as? KrevoAPIError else {
            return "Could not validate your saved session right now. Retry in a moment."
        }

        switch apiError {
        case .networkError:
            return "Could not reach Krevo right now. Check your connection and retry."
        case .rateLimited(let retryAfter):
            return "Krevo is busy right now. Retry in \(retryAfter) seconds."
        case .serverError:
            return "Krevo is temporarily unavailable. Retry in a moment."
        default:
            return "Could not validate your saved session right now. Retry in a moment."
        }
    }

    private func historyEntry(for task: UploadTask) -> HistoryEntry? {
        let completionTime = task.completionTime ?? Date()

        switch task.state {
        case .completed(let fileId):
            return HistoryEntry(
                id: task.id,
                fileName: task.fileName,
                fileSize: task.fileSize,
                shareURL: task.shareURL,
                completionTime: completionTime,
                fileId: fileId,
                result: .completed,
                message: nil
            )
        case .failed(let message):
            return HistoryEntry(
                id: task.id,
                fileName: task.fileName,
                fileSize: task.fileSize,
                shareURL: nil,
                completionTime: completionTime,
                fileId: nil,
                result: .failed,
                message: message
            )
        case .cancelled:
            return HistoryEntry(
                id: task.id,
                fileName: task.fileName,
                fileSize: task.fileSize,
                shareURL: nil,
                completionTime: completionTime,
                fileId: nil,
                result: .cancelled,
                message: nil
            )
        default:
            return nil
        }
    }
}
