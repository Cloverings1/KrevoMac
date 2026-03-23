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
                Text(storageText)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.krevoSecondary)

                Spacer()

                Text(tierLabel)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.krevoSecondary)
            }
        }
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

        if percent > 0.95 {
            colors = [Color(hex: "EF4444"), Color(hex: "DC2626")]
        } else if percent > 0.8 {
            colors = [Color(hex: "F59E0B"), Color(hex: "D97706")]
        } else {
            colors = [.krevoViolet, .krevoFuchsia]
        }

        return LinearGradient(
            colors: colors,
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}
