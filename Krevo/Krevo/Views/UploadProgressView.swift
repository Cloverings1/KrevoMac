import SwiftUI

struct UploadProgressView: View {
    @Environment(AppState.self) private var appState
    let task: UploadTask

    @State private var isHovered = false
    @State private var copyFeedbackVisible = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // File icon
            fileIcon
                .frame(width: 28, height: 28)

            // File info
            VStack(alignment: .leading, spacing: 4) {
                Text(task.fileName)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.krevoPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 188, alignment: .leading)

                progressContent
            }

            Spacer(minLength: 4)

            // Right action
            rightContent
        }
        .padding(.vertical, 6)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private enum UploadIssueKind {
        case offline
        case account
        case historyOnly
        case generic
    }

    private var hasShareLink: Bool {
        guard let shareURL = task.shareURL else { return false }
        return !shareURL.isEmpty
    }

    private var isHistoryOnly: Bool {
        task.fileURL.path == "/dev/null"
    }

    private var uploadIssueKind: UploadIssueKind {
        guard case .failed(let message) = task.state else { return .generic }
        let lowered = message.lowercased()

        if isHistoryOnly {
            return .historyOnly
        }
        if lowered.contains("authentication required") ||
            lowered.contains("sign in again") ||
            lowered.contains("session expired") ||
            lowered.contains("no active subscription")
        {
            return .account
        }
        if lowered.contains("timed out") ||
            lowered.contains("timeout") ||
            lowered.contains("connection was lost") ||
            lowered.contains("network connection") ||
            lowered.contains("not connected to the internet") ||
            lowered.contains("offline") ||
            !appState.isNetworkAvailable
        {
            return .offline
        }

        return .generic
    }

    private var canRetryInline: Bool {
        guard case .failed = task.state else { return false }
        return uploadIssueKind == .generic || uploadIssueKind == .offline
    }

    // MARK: - File Icon

    @ViewBuilder
    private var fileIcon: some View {
        switch task.state {
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(hex: "22C55E"))

        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color(hex: "EF4444"))

        case .cancelled:
            Image(systemName: "minus.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.krevoTertiary)

        default:
            fileTypeIcon
        }
    }

    private var fileTypeIcon: some View {
        let ext = (task.fileName as NSString).pathExtension.lowercased()
        let symbolName: String

        switch ext {
        case "mov", "mp4", "avi", "mkv", "webm", "m4v":
            symbolName = "film"
        case "jpg", "jpeg", "png", "gif", "heic", "webp", "tiff", "bmp":
            symbolName = "photo"
        case "mp3", "wav", "aac", "flac", "m4a", "aiff":
            symbolName = "waveform"
        case "pdf":
            symbolName = "doc.text"
        case "zip", "rar", "7z", "tar", "gz":
            symbolName = "archivebox"
        case "psd", "ai", "sketch", "fig":
            symbolName = "paintbrush"
        default:
            symbolName = "doc"
        }

        return Image(systemName: symbolName)
            .font(.system(size: 16, weight: .light))
            .foregroundStyle(Color.krevoSecondary)
    }

    // MARK: - Progress Content

    @ViewBuilder
    private var progressContent: some View {
        switch task.state {
        case .pending:
            HStack(spacing: 4) {
                Text("Waiting...")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
                Text(AppState.formatBytes(task.fileSize))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

        case .initializing:
            VStack(alignment: .leading, spacing: 4) {
                IndeterminateProgress()
                Text("Preparing upload...")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

        case .uploading:
            VStack(alignment: .leading, spacing: 4) {
                AnimatedProgress(progress: task.progress)
                    .accessibilityLabel("Upload progress")
                    .accessibilityValue("\(Int(task.progress * 100)) percent")

                Text("\(AppState.formatBytes(task.uploadedBytes)) of \(AppState.formatBytes(task.fileSize))")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoSecondary)

                if !appState.isNetworkAvailable {
                    statusPill(
                        icon: "wifi.slash",
                        title: "Offline hold",
                        tint: .krevoAmber,
                        backgroundOpacity: 0.1
                    )
                } else {
                    HStack(spacing: 0) {
                        if task.speed > 0 {
                            Text(AppState.formatSpeed(task.speed))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.krevoTertiary)
                        }

                        if let eta = task.estimatedTimeRemaining, task.speed > 0 {
                            Text(" \u{00B7} ")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.krevoTertiary)
                            Text(AppState.formatETA(eta))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.krevoTertiary)
                        }
                    }
                }
            }

        case .completing:
            VStack(alignment: .leading, spacing: 4) {
                IndeterminateProgress()
                Text("Finalizing in your account…")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

        case .completed:
            VStack(alignment: .leading, spacing: 4) {
                Text(AppState.formatBytes(task.fileSize))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)

                if copyFeedbackVisible {
                    statusPill(
                        icon: "checkmark.circle.fill",
                        title: "Link copied",
                        tint: .krevoGreen,
                        backgroundOpacity: 0.08
                    )
                } else if hasShareLink {
                    statusPill(
                        icon: "link",
                        title: "Copy link available",
                        tint: .krevoViolet,
                        backgroundOpacity: 0.08
                    )
                } else {
                    statusPill(
                        icon: "folder",
                        title: "Open in dashboard",
                        tint: .krevoSecondary,
                        backgroundOpacity: 0.05
                    )
                }
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text(failureTitle(for: message))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(failureTint.opacity(0.95))
                Text(failureSubtitle(for: message))
                    .font(.system(size: 11))
                    .foregroundStyle(failureTint.opacity(0.8))
                    .lineLimit(2)
                if uploadIssueKind == .historyOnly {
                    statusPill(
                        icon: "lock",
                        title: "Read-only history row",
                        tint: .krevoAmber,
                        backgroundOpacity: 0.08
                    )
                    .padding(.top, 3)
                }
            }

        case .cancelled:
            VStack(alignment: .leading, spacing: 4) {
                Text(isHistoryOnly ? "Cancelled earlier" : "Cancelled")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)

                if isHistoryOnly {
                    statusPill(
                        icon: "clock.arrow.circlepath",
                        title: "History only",
                        tint: .krevoTertiary,
                        backgroundOpacity: 0.06
                    )
                }
            }
        }
    }

    // MARK: - Right Content

    @ViewBuilder
    private var rightContent: some View {
        switch task.state {
        case .uploading:
            HStack(spacing: 8) {
                Text("\(Int(task.progress * 100))%")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.krevoSecondary)

                if isHovered {
                    Button {
                        appState.cancelUpload(task)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.krevoTertiary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                    .accessibilityLabel("Cancel upload")
                }
            }
            .animation(.easeInOut(duration: 0.15), value: isHovered)

        case .initializing, .pending, .completing:
            if isHovered {
                Button {
                    appState.cancelUpload(task)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.krevoTertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
                .accessibilityLabel("Cancel upload")
            }

        case .failed:
            if canRetryInline {
                Button {
                    appState.retryUpload(task)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.krevoViolet)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Retry upload")
            } else {
                issueBadge
            }

        case .completed:
            if hasShareLink {
                Button(action: copyShareLink) {
                    Text(copyFeedbackVisible ? "Copied" : "Copy link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copyFeedbackVisible ? Color.krevoGreen : Color.krevoViolet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill((copyFeedbackVisible ? Color.krevoGreen : Color.krevoAccent).opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(copyFeedbackVisible ? "Link copied" : "Copy share link")
            } else {
                Button(action: openKrevoWeb) {
                    Text("Dashboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.krevoSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color.krevoSecondaryBg)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open dashboard")
            }

        case .cancelled:
            EmptyView()
        }
    }

    private var failureTint: Color {
        switch uploadIssueKind {
        case .offline, .historyOnly:
            return .krevoAmber
        case .account:
            return .krevoRed
        case .generic:
            return .krevoRed
        }
    }

    private var issueBadge: some View {
        let title: String
        let tint: Color

        switch uploadIssueKind {
        case .account:
            title = "Account"
            tint = .krevoRed
        case .historyOnly:
            title = "History"
            tint = .krevoAmber
        case .offline:
            title = "Offline"
            tint = .krevoAmber
        case .generic:
            title = "Issue"
            tint = .krevoRed
        }

        return Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(tint.opacity(0.08))
            )
    }

    private func failureTitle(for message: String) -> String {
        switch uploadIssueKind {
        case .offline:
            return "Connection interrupted"
        case .account:
            return "Reconnect account"
        case .historyOnly:
            return "Retry needs the original file"
        case .generic:
            return "Upload failed"
        }
    }

    private func failureSubtitle(for message: String) -> String {
        switch uploadIssueKind {
        case .offline:
            return "The upload stopped when the connection dropped. Retry after you're back online."
        case .account:
            return "Your current session needs attention before this file can upload again."
        case .historyOnly:
            return "This row is now read-only. Re-open the original file or folder to upload it again."
        case .generic:
            return UploadTask.userFriendlyMessage(message)
        }
    }

    @ViewBuilder
    private func statusPill(icon: String, title: String, tint: Color, backgroundOpacity: Double) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(tint.opacity(backgroundOpacity))
        )
    }

    private func copyShareLink() {
        guard let url = task.shareURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        copyFeedbackVisible = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copyFeedbackVisible = false
        }
    }

    private func openKrevoWeb() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }
}

// MARK: - Recent Completed Row

struct RecentCompletedRow: View {
    let task: UploadTask

    @State private var now = Date()
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color(hex: "22C55E"))

            Text(task.fileName)
                .font(.system(size: 12))
                .foregroundStyle(Color.krevoSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if task.shareURL != nil {
                Button {
                    if let url = task.shareURL {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                        showCopied = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            showCopied = false
                        }
                    }
                } label: {
                    Text(showCopied ? "Copied" : "Copy link")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(showCopied ? Color.krevoGreen : Color.krevoViolet)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule()
                                .fill((showCopied ? Color.krevoGreen : Color.krevoAccent).opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showCopied ? "Link copied" : "Copy share link")
            }

            if let displayTime = task.completionTime ?? task.startTime {
                Text(AppState.formatTimeAgo(displayTime, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

            Text(AppState.formatBytes(task.fileSize))
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.fileName), uploaded \((task.completionTime ?? task.startTime).map { AppState.formatTimeAgo($0, now: now) } ?? "recently")")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }
}
