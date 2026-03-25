import SwiftUI

struct StorageMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 6) {
            // Progress bar
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

            // Labels
            HStack {
                Text(appState.storageLoaded ? storageText : "Loading...")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.krevoSecondary)

                Spacer()

                Text(tierLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.krevoSecondary)
            }
        }
        .redacted(reason: appState.storageLoaded ? [] : .placeholder)
        .accessibilityLabel(appState.storageLoaded ? "Storage: \(storageText)" : "Storage loading")
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

    private var barGradient: LinearGradient {
        let percent = appState.storagePercent

        // Smooth hue transition: violet (0.75) → amber (0.15) → red (0.0)
        let hue = 0.75 - (0.75 * min(percent, 1.0))
        let leadingColor = Color(hue: hue, saturation: 0.7, brightness: 0.9)
        let trailingColor = Color(hue: max(hue - 0.05, 0.0), saturation: 0.8, brightness: 0.85)

        return LinearGradient(
            colors: [leadingColor, trailingColor],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
