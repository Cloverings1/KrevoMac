import SwiftUI
import AppKit
import UniformTypeIdentifiers
import os

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var isSigningOut = false
    @State private var showCopiedBanner = false
    @State private var copiedBannerGeneration: UInt64 = 0
    @State private var activeTab: PanelTab = .activity
    @State private var rootDropTargeted = false

    enum PanelTab: String, CaseIterable, Identifiable {
        case activity, files, account
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    var body: some View {
        Group {
            if appState.isCheckingAuth {
                loadingView
            } else if appState.shouldPresentAuthenticatedShell {
                authenticatedView
            } else {
                AuthView()
            }
        }
        .frame(width: 360, height: 560)
        .background(Color.krevoBg)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(Color.krevoAccentInk)
            Spacer()
        }
        .frame(height: 200)
    }

    // MARK: - Authenticated

    private var authenticatedView: some View {
        VStack(spacing: 0) {
            header

            tabs

            if let banner = appState.globalBanner {
                globalBannerView(banner)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }

            if let notice = sessionNotice {
                notice
                    .padding(.horizontal, 12)
                    .padding(.top, appState.globalBanner == nil ? 10 : 8)
            }

            if appState.showCompletionBanner {
                completionBanner
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    switch activeTab {
                    case .activity:
                        activityTab
                    case .files:
                        filesTab
                    case .account:
                        accountTab
                    }
                }
            }
            .scrollIndicators(.hidden)

            actionsRow

            footerView
        }
        .frame(width: 360)
        .onDrop(of: [.fileURL], isTargeted: $rootDropTargeted) { providers in
            handleRootDrop(providers)
            return true
        }
        .overlay {
            if rootDropTargeted {
                dragOverlay
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: rootDropTargeted)
    }

    private var dragOverlay: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.krevoAccent.opacity(0.55))
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(
                    Color.krevoAccentInk.opacity(0.6),
                    style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                )
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.up.on.square")
                    .font(.system(size: 28, weight: .regular))
                Text("Drop to upload instantly")
                    .font(.system(size: 15, weight: .semibold))
                    .kerning(-0.2)
            }
            .foregroundStyle(Color.krevoAccentInk)
        }
        .padding(6)
        .allowsHitTesting(false)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            avatar

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.krevoPrimary)
                    .kerning(-0.2)

                HStack(spacing: 7) {
                    BreathingDot(color: statusColor)
                    Text(statusText)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(statusColor)
                }
            }

            Spacer(minLength: 0)

            Button(action: openPreferences) {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.krevoTertiary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.clear)
                    )
            }
            .buttonStyle(.plain)
            .help("Open dashboard in browser")
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.krevoBorder).frame(height: 1)
        }
        .background(
            LinearGradient(
                colors: [Color.white.opacity(0.9), Color.white.opacity(0.6)],
                startPoint: .top, endPoint: .bottom
            )
        )
    }

    private var avatar: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.krevoAccent.mix(with: .white, ratio: 0.2), Color.krevoAccent],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ))
            Circle()
                .stroke(Color.white.opacity(0.6), lineWidth: 1)
            Text(initials)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.krevoAccentInk)
                .kerning(0.4)
        }
        .frame(width: 34, height: 34)
    }

    private var initials: String {
        let source: String
        if !appState.userName.isEmpty {
            source = appState.userName
        } else if !appState.userEmail.isEmpty {
            source = appState.userEmail.components(separatedBy: "@").first ?? appState.userEmail
        } else {
            return "K"
        }

        let parts = source.split(separator: " ").prefix(2)
        let chars = parts.compactMap { $0.first.map(String.init) }
        return chars.isEmpty ? "K" : chars.joined().uppercased()
    }

    private var displayName: String {
        appState.accountDisplayName
    }

    private var statusText: String {
        if !appState.isNetworkAvailable { return "Offline" }
        if appState.hasActiveUploads {
            let count = appState.activeUploads.count
            return count == 1 ? "Uploading 1 file" : "Uploading \(count) files"
        }
        if case .readOnly(let reason) = appState.accountAccessState {
            return reason.statusText
        }
        if !appState.isSessionValidated {
            return "Reconnect to verify session"
        }
        let failed = terminalTasks.filter { if case .failed = $0.state { return true } else { return false } }.count
        if failed > 0 {
            return failed == 1 ? "1 upload needs attention" : "\(failed) uploads need attention"
        }
        return "All caught up"
    }

    private var statusColor: Color {
        if appState.hasActiveUploads { return Color.krevoAccentInk }
        if !appState.isNetworkAvailable { return .krevoAmber }
        if appState.isReadOnlyAccount { return .krevoAmber }
        if !appState.isSessionValidated { return .krevoAmber }
        let hasFailed = terminalTasks.contains { if case .failed = $0.state { return true } else { return false } }
        if hasFailed { return .krevoAmber }
        return .krevoGreen
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PanelTab.allCases) { tab in
                TabPill(
                    title: tab.title,
                    isActive: activeTab == tab,
                    action: { withAnimation(.easeInOut(duration: 0.18)) { activeTab = tab } }
                )
            }
        }
        .padding(6)
        .background(Color.krevoSecondaryBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.krevoBorder).frame(height: 1)
        }
    }

    // MARK: - Activity Tab

    @ViewBuilder
    private var activityTab: some View {
        StorageMeterView()
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

        if !appState.canStartUploads {
            uploadAvailabilityCard
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
        }

        if appState.hasActiveUploads {
            sectionHeader(title: "Uploading now", actionTitle: nil, action: nil)
            VStack(spacing: 0) {
                ForEach(appState.activeUploads) { task in
                    UploadProgressView(task: task)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 4)
        }

        if hasTerminalUploads {
            sectionHeader(
                title: "Issues",
                actionTitle: "Clear",
                action: { appState.clearCompleted() }
            )
            VStack(spacing: 0) {
                ForEach(terminalTasks) { task in
                    UploadProgressView(task: task)
                        .padding(.horizontal, 14)
                }
            }
        }

        if appState.canStartUploads {
            UploadDropZone(compact: appState.hasActiveUploads)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 4)
        }

        if !appState.recentCompleted.isEmpty {
            sectionHeader(
                title: "Recently synced",
                actionTitle: "Open dashboard ↗",
                action: openKrevoWeb
            )
            filesList(tasks: Array(appState.recentCompleted.prefix(4)))
        }
    }

    // MARK: - Files Tab

    @ViewBuilder
    private var filesTab: some View {
        sectionHeader(
            title: "Recently synced",
            actionTitle: "Open dashboard ↗",
            action: openKrevoWeb
        )
        if appState.recentCompleted.isEmpty {
            emptyState(icon: "tray", title: "No files yet", subtitle: "Your recent uploads will appear here.")
        } else {
            filesList(tasks: appState.recentCompleted)
        }
    }

    // MARK: - Account Tab

    @ViewBuilder
    private var accountTab: some View {
        StorageMeterView()
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 18)

        VStack(alignment: .leading, spacing: 0) {
            accountRow(label: "Name", value: displayName)
            Divider().background(Color.krevoBorder)
            accountRow(label: "Plan", value: appState.accountPlanLabel)
            Divider().background(Color.krevoBorder)
            accountRow(label: "Access", value: accessSummary)
            Divider().background(Color.krevoBorder)
            accountRow(
                label: "Storage",
                value: appState.storageLoaded
                    ? "\(AppState.formatBytes(appState.storageUsed)) / \(AppState.formatBytes(appState.storageLimit))"
                    : "—"
            )
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 14)

        if !appState.canStartUploads {
            uploadAvailabilityCard
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
        }

        Button(action: { Task {
            isSigningOut = true
            await appState.signOut()
            isSigningOut = false
        } }) {
            HStack {
                if isSigningOut {
                    ProgressView().controlSize(.mini).tint(Color.krevoTertiary)
                } else {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                        .font(.system(size: 12, weight: .medium))
                }
                Text(isSigningOut ? "Signing out…" : "Sign out")
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(Color.krevoRed)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(Color.krevoRed.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(Color.krevoRed.opacity(0.18), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(isSigningOut)
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func accountRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.krevoTertiary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.krevoPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
    }

    // MARK: - Shared section pieces

    private func sectionHeader(title: String, actionTitle: String?, action: (() -> Void)?) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.8)
                .foregroundStyle(Color.krevoQuaternary)
            Spacer()
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.krevoTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func filesList(tasks: [UploadTask]) -> some View {
        VStack(spacing: 2) {
            ForEach(tasks) { task in
                FileRow(task: task)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color.krevoQuaternary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.krevoSecondary)
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoQuaternary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Actions row

    private var actionsRow: some View {
        HStack(spacing: 6) {
            ActionTile(
                icon: "arrow.up",
                title: "Upload",
                style: .primary,
                disabled: !appState.canStartUploads,
                action: openFilePicker
            )
            ActionTile(
                icon: "folder",
                title: "Open dashboard",
                style: .normal,
                action: openKrevoWeb
            )
            ActionTile(
                icon: "link",
                title: "Share link",
                style: .normal,
                disabled: !hasShareableUpload,
                action: shareLatestLink
            )
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(
            LinearGradient(
                colors: [Color.clear, Color.krevoSecondaryBg.opacity(0.5)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .overlay(alignment: .top) {
            Rectangle().fill(Color.krevoBorder).frame(height: 1)
        }
    }

    // MARK: - Uploading helpers

    private var hasTerminalUploads: Bool {
        appState.uploadTasks.contains { task in
            if case .failed = task.state { return true }
            if case .cancelled = task.state { return true }
            return false
        }
    }

    private var hasShareableUpload: Bool {
        appState.recentCompleted.contains { $0.shareURL != nil }
    }

    private var terminalTasks: [UploadTask] {
        appState.uploadTasks.filter { task in
            if case .failed = task.state { return true }
            if case .cancelled = task.state { return true }
            return false
        }
    }

    private var accessSummary: String {
        switch appState.accountAccessState {
        case .fullAccess:
            return appState.isSessionValidated ? "Full access" : "Reconnect required"
        case .readOnly(let reason):
            return reason.title
        case .unknown:
            return appState.isSessionValidated ? "Unavailable" : "Reconnect required"
        }
    }

    private var sessionNotice: AnyView? {
        if appState.globalBanner != .networkOffline && !appState.isSessionValidated {
            return AnyView(bannerCard(
                icon: "arrow.clockwise.circle",
                title: "Reconnect required",
                message: appState.authMessage ?? "Reconnect to refresh your Krevo session.",
                color: .krevoAmber
            ))
        } else if case .readOnly(let reason) = appState.accountAccessState {
            return AnyView(bannerCard(
                icon: "lock.fill",
                title: reason.title,
                message: reason.message,
                color: .krevoAmber
            ))
        }
        return nil
    }

    private var uploadAvailabilityCard: some View {
        bannerCard(
            icon: appState.isReadOnlyAccount ? "lock.fill" : "wifi.exclamationmark",
            title: appState.isReadOnlyAccount ? "Uploads locked" : "Uploads unavailable",
            message: appState.uploadAvailabilityMessage,
            color: .krevoAmber
        )
    }

    // MARK: - Banners (kept from previous implementation)

    @ViewBuilder
    private func globalBannerView(_ banner: GlobalBanner) -> some View {
        switch banner {
        case .networkOffline:
            bannerCard(icon: "wifi.slash", title: "Offline",
                       message: "Uploads pause until your connection returns.",
                       color: .krevoAmber)
        case .authRequired:
            bannerCard(icon: "person.crop.circle.badge.exclamationmark",
                       title: "Sign in again",
                       message: "Your device session expired.",
                       color: .krevoRed)
        case .quotaIssue(let message):
            bannerCard(icon: "externaldrive.badge.exclamationmark",
                       title: "Storage limit reached", message: message, color: .krevoAmber)
        case .serverAnnouncement(let message):
            bannerCard(icon: "megaphone.fill", title: "Notice", message: message,
                       color: .krevoAccentInk)
        }
    }

    private func bannerCard(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.krevoPrimary)
                Text(message).font(.system(size: 11))
                    .foregroundStyle(Color.krevoSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.2), lineWidth: 1))
    }

    private var completionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color.krevoGreen)
            Text(appState.completedFileName)
                .font(.system(size: 12))
                .foregroundStyle(Color.krevoSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(showCopiedBanner ? "Link copied!" : "uploaded")
                .font(.system(size: 11))
                .foregroundStyle(showCopiedBanner ? Color.krevoGreen : Color.krevoTertiary)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.krevoGreen.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.krevoGreen.opacity(0.2), lineWidth: 1))
        .onChange(of: appState.completedFileName) { _, _ in
            copiedBannerGeneration &+= 1
            showCopiedBanner = false
        }
        .onTapGesture {
            if let url = appState.completedShareURL {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
                copiedBannerGeneration &+= 1
                let generation = copiedBannerGeneration
                showCopiedBanner = true
                // Reset the banner's dismissal timer so the "Link copied!" label
                // stays visible for the full 1.5s instead of racing with the
                // original 3s countdown.
                appState.presentCompletionBanner(
                    fileName: appState.completedFileName,
                    shareURL: url,
                    duration: 1.5
                )
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(1.5))
                    guard copiedBannerGeneration == generation else { return }
                    showCopiedBanner = false
                }
            } else {
                appState.showCompletionBanner = false
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            HStack(spacing: 6) {
                Text("Krevo")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.krevoTertiary)
                Text(versionString)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color.krevoQuaternary)
            }
            Spacer()
            HStack(spacing: 4) {
                FootButton(icon: "gearshape", tooltip: "Open dashboard", action: openPreferences)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.krevoSecondaryBg)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.krevoBorder).frame(height: 1)
        }
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let releaseName = Bundle.main.object(forInfoDictionaryKey: "KrevoReleaseName") as? String
        let version = short ?? "1.0"

        if let releaseName, !releaseName.isEmpty {
            return "v\(version) \(releaseName)"
        }

        return "v\(version)"
    }

    // MARK: - Actions

    private func openFilePicker() {
        guard appState.canStartUploads else {
            appState.handleBlockedUploadAttempt()
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.title = "Select Files or Folders to Upload"
        if panel.runModal() == .OK {
            appState.startUpload(urls: panel.urls)
        }
    }

    private func openKrevoWeb() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }

    private func shareLatestLink() {
        guard let latest = appState.recentCompleted.first(where: { $0.shareURL != nil }),
              let url = latest.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        appState.presentCompletionBanner(fileName: latest.fileName, shareURL: url, duration: 2)
    }

    private func handleRootDrop(_ providers: [NSItemProvider]) {
        Task { @MainActor in
            guard appState.canStartUploads else {
                appState.handleBlockedUploadAttempt()
                return
            }
            var urls: [URL] = []
            for provider in providers {
                guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
                if let url = await loadFileURL(from: provider) { urls.append(url) }
            }
            if !urls.isEmpty {
                appState.startUpload(urls: urls)
                withAnimation(.easeInOut(duration: 0.18)) { activeTab = .activity }
            } else if !providers.isEmpty {
                KrevoConstants.uploadLogger.warning("Drop resolved no valid file URLs from \(providers.count) provider(s)")
                let failed = UploadTask(
                    failedURL: URL(filePath: "dropped items"),
                    message: "Dropped items could not be read as files"
                )
                appState.uploadTasks.insert(failed, at: 0)
            }
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: url)
            }
        }
    }

    private func openPreferences() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }
}

// MARK: - Tab pill

private struct TabPill: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? Color.krevoPrimary : (hovered ? Color.krevoSecondary : Color.krevoTertiary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(isActive ? Color.white : Color.clear)
                        .shadow(color: isActive ? Color.black.opacity(0.05) : .clear, radius: 1, y: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Status dot

// Calm, non-animating dot. The previous version had a repeatForever pulse
// that could stack on popover reopens and read as 'weird' to the eye —
// a steady indicator suits the 'All caught up' state better.
private struct BreathingDot: View {
    let color: Color

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.18))
                .frame(width: 13, height: 13)
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
        }
        .frame(width: 13, height: 13)
    }
}

// MARK: - Action tile (3-up grid)

private struct ActionTile: View {
    enum Style { case primary, normal }
    let icon: String
    let title: String
    let style: Style
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9)
                        .fill(iconBg)
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(iconBorder, lineWidth: 1)
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(iconFg)
                }
                .frame(width: 30, height: 30)

                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(disabled ? Color.krevoQuaternary : Color.krevoSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(hovered && !disabled ? Color.krevoSecondaryBg : Color.clear)
            )
            .opacity(disabled ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .onHover { hovered = $0 }
    }

    private var iconBg: Color {
        switch style {
        case .primary: return Color.krevoAccent.opacity(0.35)
        case .normal:  return .white
        }
    }
    private var iconBorder: Color {
        switch style {
        case .primary: return Color.krevoAccent.opacity(0.55)
        case .normal:  return Color.krevoBorder
        }
    }
    private var iconFg: Color {
        switch style {
        case .primary: return Color.krevoAccentInk
        case .normal:  return hovered ? Color.krevoPrimary : Color.krevoSecondary
        }
    }
}

// MARK: - Foot button

private struct FootButton: View {
    let icon: String
    let tooltip: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? Color.krevoPrimary : Color.krevoTertiary)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(hovered ? Color.white : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .help(tooltip)
        .onHover { hovered = $0 }
    }
}

// MARK: - File row (colored tile + name + status)

private struct FileRow: View {
    let task: UploadTask
    @State private var hovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 12) {
            fileTile
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 1) {
                Text(task.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.krevoPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(metaLine)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.krevoQuaternary)
            }

            Spacer(minLength: 4)

            statusBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(hovered ? Color.krevoSecondaryBg : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { copyLinkIfAvailable() }
    }

    private var metaLine: String {
        let size = AppState.formatBytes(task.fileSize)
        let kind = kindLabel
        if let when = task.completionTime ?? task.startTime {
            return "\(size) · \(kind) · \(AppState.formatTimeAgo(when, now: Date()))"
        }
        return "\(size) · \(kind)"
    }

    private var kindLabel: String {
        let ext = (task.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp": return "photos"
        case "mov", "mp4", "avi", "mkv", "webm", "m4v": return "video"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff": return "audio"
        case "pdf", "pages", "doc", "docx", "txt", "md", "rtf": return "docs"
        case "zip", "rar", "7z", "tar", "gz": return "archive"
        default: return "file"
        }
    }

    private var fileTile: some View {
        let kind = fileKind
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(kind.gradient)
            RoundedRectangle(cornerRadius: 8)
                .stroke(kind.border, lineWidth: 1)
            if kind == .folder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(kind.ink)
            } else {
                Text(kind.tag)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.4)
                    .foregroundStyle(kind.ink)
            }
        }
    }

    private enum FileKind {
        case image, video, doc, archive, folder, generic
        var tag: String {
            switch self {
            case .image: return "IMG"
            case .video: return "VID"
            case .doc: return "DOC"
            case .archive: return "ZIP"
            case .folder: return "FLDR"
            case .generic: return "FILE"
            }
        }
        var gradient: LinearGradient {
            let colors: [Color]
            switch self {
            case .image:   colors = [Color(hex: "FFE8E6"), Color(hex: "FFD4CF")]
            case .video:   colors = [Color(hex: "E6F0FF"), Color(hex: "CEE0FE")]
            case .doc:     colors = [Color(hex: "EEF7E8"), Color(hex: "D9EECA")]
            case .archive: colors = [Color(hex: "FDF3D7"), Color(hex: "F7E4A7")]
            case .folder:  colors = [Color(hex: "EAEBEF"), Color(hex: "D6D9E0")]
            case .generic: colors = [Color.white, Color(hex: "F2F3F5")]
            }
            return LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        var border: Color {
            switch self {
            case .image:   return Color(hex: "FBD9D4")
            case .video:   return Color(hex: "D4E4FE")
            case .doc:     return Color(hex: "DDEDCE")
            case .archive: return Color(hex: "F6E4A9")
            case .folder:  return Color(hex: "DCDFE6")
            case .generic: return Color(hex: "E8E8EC")
            }
        }
        var ink: Color {
            switch self {
            case .image:   return Color(hex: "B7402A")
            case .video:   return Color(hex: "1E3A8A")
            case .doc:     return Color(hex: "3F7A1F")
            case .archive: return Color(hex: "8A651B")
            case .folder:  return Color(hex: "3C3C43")
            case .generic: return Color(hex: "6E6E76")
            }
        }
    }

    private var fileKind: FileKind {
        let ext = (task.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp": return .image
        case "mov", "mp4", "avi", "mkv", "webm", "m4v": return .video
        case "pdf", "pages", "doc", "docx", "txt", "md", "rtf": return .doc
        case "zip", "rar", "7z", "tar", "gz": return .archive
        case "": return .folder
        default: return .generic
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        if showCopied {
            Text("Copied!")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.krevoGreen)
        } else if task.shareURL != nil && hovered {
            Image(systemName: "link")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.krevoAccentInk)
        } else {
            ZStack {
                Circle()
                    .fill(Color.krevoAccent.opacity(0.35))
                    .frame(width: 16, height: 16)
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.krevoAccentInk)
            }
        }
    }

    private func copyLinkIfAvailable() {
        guard let url = task.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        showCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.4))
            showCopied = false
        }
    }
}

// MARK: - Color mixing helper

private extension Color {
    func mix(with other: Color, ratio: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.deviceRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.deviceRGB) ?? .white
        let r = Double(a.redComponent) * (1 - ratio) + Double(b.redComponent) * ratio
        let g = Double(a.greenComponent) * (1 - ratio) + Double(b.greenComponent) * ratio
        let bl = Double(a.blueComponent) * (1 - ratio) + Double(b.blueComponent) * ratio
        return Color(red: r, green: g, blue: bl)
    }
}
