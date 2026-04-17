import SwiftUI

struct StorageMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.krevoBorder)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(barGradient)
                        .frame(width: max(0, geo.size.width * min(appState.storagePercent, 1.0)))
                        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: appState.storagePercent)
                }
            }
            .frame(height: 4)

            HStack {
                Text(appState.storageLoaded ? storageText : "Loading...")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.krevoSecondary)

                Spacer()

                Text(tierLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.krevoSecondary)
            }

            HStack(spacing: 8) {
                Text(remainingText)
                Spacer(minLength: 8)

                if let maxFileText {
                    Text(maxFileText)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.krevoTertiary)

            if let statusLine {
                HStack(spacing: 6) {
                    Image(systemName: statusLine.icon)
                        .font(.system(size: 10, weight: .semibold))
                    Text(statusLine.text)
                        .lineLimit(2)
                }
                .font(.system(size: 10))
                .foregroundStyle(statusLine.color)
            }
        }
        .redacted(reason: appState.storageLoaded ? [] : .placeholder)
        .accessibilityLabel(accessibilityLabel)
    }

    // MARK: - Computed

    private var storageText: String {
        let used = AppState.formatBytes(appState.storageUsed)
        let limit = AppState.formatBytes(appState.storageLimit)
        return "\(used) / \(limit)"
    }

    private var tierLabel: String {
        appState.tier.isEmpty ? "" : appState.tier.capitalized
    }

    private var remainingText: String {
        "Available \(AppState.formatBytes(appState.remainingStorage))"
    }

    private var maxFileText: String? {
        guard appState.maxFileSize > 0 else { return nil }
        return "Max file \(AppState.formatBytes(appState.maxFileSize))"
    }

    private var statusLine: (icon: String, text: String, color: Color)? {
        if let error = appState.storageErrorMessage {
            return ("exclamationmark.triangle.fill", error, .krevoAmber)
        }

        if appState.storageLoaded && appState.isStorageStale {
            return ("arrow.clockwise", "Storage info is older than 5 minutes.", .krevoTertiary)
        }

        return nil
    }

    private var accessibilityLabel: String {
        guard appState.storageLoaded else { return "Storage loading" }

        var parts = [storageText, remainingText]
        if let maxFileText {
            parts.append(maxFileText)
        }
        if let statusLine {
            parts.append(statusLine.text)
        }
        return "Storage: \(parts.joined(separator: ", "))"
    }

    private var barGradient: LinearGradient {
        let percent = appState.storagePercent

        let colors: [Color]
        switch percent {
        case ..<0.65:
            colors = [.krevoViolet, .krevoFuchsia]
        case ..<0.85:
            colors = [.krevoFuchsia, .krevoAmber]
        case ..<0.95:
            colors = [.krevoAmber, .krevoCoral]
        default:
            colors = [.krevoCoral, .krevoRed]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
