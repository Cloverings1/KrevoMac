import SwiftUI

struct StorageMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            StorageRing(percent: ringPercent)
                .frame(width: 92, height: 92)

            VStack(alignment: .leading, spacing: 0) {
                if appState.storageLoaded {
                    HStack(spacing: 0) {
                        Text(usedPrimary)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.krevoPrimary)
                        Text(" of \(limitText)")
                            .foregroundStyle(Color.krevoSecondary)
                    }
                    .font(.system(size: 13))
                } else {
                    Text("Loading…")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.krevoSecondary)
                }

                Text(remainingText)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Color.krevoQuaternary)
                    .padding(.top, 3)

                if appState.storageLoaded {
                    HStack(spacing: 8) {
                        planBadge
                        Button(action: openManage) {
                            Text("Manage")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.krevoAccentInk.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var ringPercent: Int {
        guard appState.storageLimit > 0 else { return 0 }
        let raw = Double(appState.storageUsed) / Double(appState.storageLimit) * 100.0
        return min(100, max(0, Int(raw.rounded())))
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

    private var tierLabel: String {
        appState.tier.isEmpty ? "Free" : appState.tier.capitalized
    }

    private var planBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color.krevoAccentInk.opacity(0.7))
                .frame(width: 5, height: 5)
            Text("\(tierLabel) plan")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.krevoAccentInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(Color.krevoAccent.opacity(0.3))
        )
    }

    private func openManage() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }

    private var accessibilityLabel: String {
        guard appState.storageLoaded else { return "Storage loading" }
        return "\(usedPrimary) used of \(limitText). \(remainingText). \(tierLabel) plan."
    }
}

// MARK: - Ring

struct StorageRing: View {
    let percent: Int
    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.krevoBorder, lineWidth: 6)

            Circle()
                .trim(from: 0, to: CGFloat(animated / 100.0))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: [.krevoAccent, .krevoAccentDeep]),
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.spring(response: 1.0, dampingFraction: 0.85), value: animated)

            VStack(spacing: 2) {
                Text("\(percent)%")
                    .font(.system(size: 22, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.krevoPrimary)
                    .kerning(-0.5)
                Text("USED")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.8)
                    .foregroundStyle(Color.krevoQuaternary)
            }
        }
        .onAppear { animated = Double(percent) }
        .onChange(of: percent) { _, newValue in animated = Double(newValue) }
    }
}
