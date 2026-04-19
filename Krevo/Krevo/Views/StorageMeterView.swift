import SwiftUI

struct StorageMeterView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(alignment: .center, spacing: 18) {
            StorageRing(percent: ringPercent, accentColors: ringAccentColors)
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

                HStack(spacing: 6) {
                    statusBadge(
                        icon: primaryStatusIcon,
                        title: primaryStatusTitle,
                        tint: primaryStatusTint
                    )
                    if let accessBadge = accessBadge {
                        accessBadge
                    }
                }
                .padding(.top, 8)

                if let storageErrorMessage = appState.storageErrorMessage {
                    Label(storageErrorMessage, systemImage: "clock.arrow.circlepath")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.krevoAmber)
                        .padding(.top, 6)
                }

                if appState.storageLoaded {
                    HStack(spacing: 8) {
                        planBadge
                        Button(action: openManage) {
                            Text(manageButtonTitle)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.krevoAccentInk.opacity(0.75))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.top, 10)
                }

                Text(statusFootnote)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color.krevoQuaternary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var ringPercent: Int {
        guard appState.storageLimit > 0 else { return 0 }
        let reservedAwareUsed = min(appState.storageLimit, appState.storageUsed + appState.reservedUploadBytes)
        let raw = Double(reservedAwareUsed) / Double(appState.storageLimit) * 100.0
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
        appState.accountPlanLabel
    }

    private var primaryStatusTitle: String {
        if !appState.isNetworkAvailable { return "Offline" }
        if !appState.isSessionValidated { return "Reconnect required" }
        if appState.storageErrorMessage != nil { return "Status delayed" }
        return "Account connected"
    }

    private var primaryStatusIcon: String {
        if !appState.isNetworkAvailable { return "wifi.slash" }
        if !appState.isSessionValidated { return "arrow.clockwise.circle" }
        if appState.storageErrorMessage != nil { return "clock.arrow.circlepath" }
        return "checkmark.circle.fill"
    }

    private var primaryStatusTint: Color {
        if !appState.isNetworkAvailable { return .krevoAmber }
        if !appState.isSessionValidated { return .krevoAmber }
        if appState.storageErrorMessage != nil { return .krevoAmber }
        return .krevoGreen
    }

    private var manageButtonTitle: String {
        appState.storageErrorMessage == nil ? "Manage" : "Open dashboard"
    }

    private var statusFootnote: String {
        if !appState.isNetworkAvailable {
            return "Uploads pause while you're offline and pick back up when the connection returns."
        }
        if !appState.isSessionValidated {
            return "Krevo is keeping your local shell open, but the session needs to reconnect before new uploads can start."
        }
        if case .readOnly(let reason) = appState.accountAccessState {
            return appState.serverUpgradeMessage ?? reason.message
        }
        if appState.storageErrorMessage != nil {
            return "Usage may be slightly stale right now. Open the dashboard if this keeps showing up."
        }
        return "macOS only grants Krevo read-only access to files you pick. After a relaunch, re-open the original file or folder if you need to retry."
    }

    private var ringAccentColors: [Color] {
        if !appState.isNetworkAvailable || !appState.isSessionValidated || appState.storageErrorMessage != nil {
            return [Color.krevoAmber, Color.krevoAccentDeep]
        }
        if ringPercent >= 90 {
            return [Color.krevoAmber, Color.krevoRed]
        }
        return [Color.krevoAccent, Color.krevoAccentDeep]
    }

    private var accessBadge: AnyView? {
        switch appState.accountAccessState {
        case .readOnly(let reason):
            return AnyView(statusBadge(icon: "lock", title: reason.title, tint: .krevoAmber))
        case .fullAccess:
            return AnyView(statusBadge(icon: "arrow.up.circle", title: "Uploads enabled", tint: .krevoSecondary))
        case .unknown:
            return nil
        }
    }

    private var planBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill((appState.isReadOnlyAccount ? Color.krevoAmber : Color.krevoAccentInk).opacity(0.7))
                .frame(width: 5, height: 5)
            Text(planBadgeTitle)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(appState.isReadOnlyAccount ? Color.krevoAmber : Color.krevoAccentInk)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((appState.isReadOnlyAccount ? Color.krevoAmber : Color.krevoAccent).opacity(0.2))
        )
    }

    private var planBadgeTitle: String {
        if case .readOnly = appState.accountAccessState {
            return "\(tierLabel) read-only"
        }
        return "\(tierLabel) plan"
    }

    private func statusBadge(icon: String, title: String, tint: Color) -> some View {
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
                .fill(tint.opacity(0.08))
        )
    }

    private func openManage() {
        NSWorkspace.shared.open(KrevoConstants.baseURL)
    }

    private var accessibilityLabel: String {
        guard appState.storageLoaded else { return "Storage loading" }
        if let storageErrorMessage = appState.storageErrorMessage {
            return "\(usedPrimary) used of \(limitText). \(remainingText). \(planBadgeTitle). \(primaryStatusTitle). \(storageErrorMessage)"
        }
        return "\(usedPrimary) used of \(limitText). \(remainingText). \(planBadgeTitle). \(primaryStatusTitle)."
    }
}

// MARK: - Ring

struct StorageRing: View {
    let percent: Int
    let accentColors: [Color]
    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.krevoBorder, lineWidth: 6)

            Circle()
                .trim(from: 0, to: CGFloat(animated / 100.0))
                .stroke(
                    AngularGradient(
                        gradient: Gradient(colors: accentColors),
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
