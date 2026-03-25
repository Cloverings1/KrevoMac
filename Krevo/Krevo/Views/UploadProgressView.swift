import SwiftUI

struct UploadProgressView: View {
    @Environment(AppState.self) private var appState
    let task: UploadTask

    @State private var isHovered = false

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
                    .frame(maxWidth: 200, alignment: .leading)

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
                    Text("Waiting for network...")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.krevoTertiary)
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
                Text("Finalizing...")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

        case .completed:
            Text(AppState.formatBytes(task.fileSize))
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)

        case .failed(let message):
            VStack(alignment: .leading, spacing: 2) {
                Text("Upload failed")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color(hex: "EF4444").opacity(0.95))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: "EF4444").opacity(0.8))
                    .lineLimit(2)
            }

        case .cancelled:
            Text("Cancelled")
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)
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
            Button {
                appState.retryUpload(task)
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.krevoViolet)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry upload")

        case .completed, .cancelled:
            EmptyView()
        }
    }
}

// MARK: - Recent Completed Row

struct RecentCompletedRow: View {
    let task: UploadTask

    @State private var now = Date()

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
                    }
                } label: {
                    Image(systemName: "link")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.krevoViolet)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy share link")
            }

            if let startTime = task.startTime {
                Text(AppState.formatTimeAgo(startTime, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }

            Text(AppState.formatBytes(task.fileSize))
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.fileName), uploaded \(task.startTime.map { AppState.formatTimeAgo($0, now: now) } ?? "recently")")
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }
}
