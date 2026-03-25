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
