import SwiftUI

struct StorageMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Storage")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.krevoQuaternary)

                Spacer(minLength: 0)

                if appState.storageLoaded {
                    Button(action: openManage) {
                        Text("Manage")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.krevoAccentInk.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }

            if appState.storageLoaded {
                HStack(spacing: 0) {
                    Text(usedPrimary)
                        .font(.system(size: 16, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Color.krevoPrimary)
                    Text(" of \(limitText)")
                        .font(.system(size: 15).monospacedDigit())
                        .foregroundStyle(Color.krevoSecondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            } else {
                Text("Loading…")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.krevoSecondary)
            }

            if appState.storageLoaded {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(remainingText)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Color.krevoTertiary)

                    Spacer(minLength: 0)

                    Text(usedStatusText)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(progressLabelColor)
                }
            }

            if let storageErrorMessage = appState.storageErrorMessage {
                Text(storageErrorMessage)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.krevoAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if appState.storageLoaded {
                    StorageProgressBar(
                        progress: storageProgress,
                        accentColors: progressAccentColors
                    )
                } else {
                    IndeterminateProgress(height: 6)
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var reservedAwareUsed: Int64 {
        guard appState.storageLimit > 0 else { return 0 }
        return min(appState.storageLimit, appState.storageUsed + appState.reservedUploadBytes)
    }

    private var storageProgress: Double {
        guard appState.storageLimit > 0 else { return 0 }
        let raw = Double(reservedAwareUsed) / Double(appState.storageLimit)
        return min(1, max(0, raw))
    }

    private var storagePercent: Int {
        Int((storageProgress * 100).rounded())
    }

    private var usedPrimary: String {
        appState.storageLoaded ? AppState.formatBytes(appState.storageUsed) : "—"
    }

    private var limitText: String {
        appState.storageLoaded ? AppState.formatBytes(appState.storageLimit) : "—"
    }

    private var remainingText: String {
        guard appState.storageLoaded else { return " " }
        return "\(AppState.formatBytes(appState.remainingStorage)) remaining"
    }

    private var usedStatusText: String {
        "\(storagePercent)% used"
    }

    private var progressAccentColors: [Color] {
        if !appState.isNetworkAvailable || !appState.isSessionValidated || appState.storageErrorMessage != nil {
            return [Color.krevoAmber, Color.krevoAccentDeep]
        }
        if storagePercent >= 90 {
            return [Color.krevoAmber, Color.krevoRed]
        }
        return [Color.krevoAccent, Color.krevoAccentDeep]
    }

    private var progressLabelColor: Color {
        if !appState.isNetworkAvailable || !appState.isSessionValidated || appState.storageErrorMessage != nil {
            return .krevoAmber
        }
        if storagePercent >= 90 {
            return .krevoRed
        }
        return .krevoTertiary
    }

    private func openManage() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }

    private var accessibilityLabel: String {
        guard appState.storageLoaded else { return "Storage loading" }
        if let storageErrorMessage = appState.storageErrorMessage {
            return "\(usedPrimary) used of \(limitText). \(storagePercent) percent used. \(remainingText). \(storageErrorMessage)"
        }
        return "\(usedPrimary) used of \(limitText). \(storagePercent) percent used. \(remainingText)."
    }
}

// MARK: - Progress

struct StorageProgressBar: View {
    let progress: Double
    let accentColors: [Color]
    var height: CGFloat = 6

    @State private var animatedProgress: CGFloat = 0

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.krevoBorderSoft)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: accentColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: fillWidth(in: geometry.size.width))
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: animatedProgress)
        .onAppear { animatedProgress = clampedProgress }
        .onChange(of: progress) { _, _ in animatedProgress = clampedProgress }
    }

    private var clampedProgress: CGFloat {
        CGFloat(min(1, max(0, progress)))
    }

    private func fillWidth(in totalWidth: CGFloat) -> CGFloat {
        guard animatedProgress > 0 else { return 0 }
        return max(height, totalWidth * animatedProgress)
    }
}
