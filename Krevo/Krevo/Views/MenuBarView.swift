import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var appeared = false

    var body: some View {
        Group {
            if appState.isCheckingAuth {
                loadingView
            } else if appState.isAuthenticated {
                authenticatedView
            } else {
                AuthView()
            }
        }
        .frame(width: 320, height: 560)
        .background(Color.krevoBg)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack {
            Spacer()
            ProgressView()
                .controlSize(.small)
                .tint(Color.krevoViolet)
            Spacer()
        }
        .frame(height: 200)
    }

    // MARK: - Authenticated

    private var authenticatedView: some View {
        VStack(spacing: 0) {
            if let banner = appState.globalBanner {
                globalBannerView(banner)
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
            }

            if appState.showCompletionBanner {
                completionBanner
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    // Greeting + weather
                    greetingRow
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 8)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -8)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: appeared)

                    // Storage meter
                    StorageMeterView()
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : -6)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.05), value: appeared)

                    Divider()
                        .background(Color.krevoBorder)

                    // Drop zone (always visible)
                    UploadDropZone(compact: appState.hasActiveUploads)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .scaleEffect(appeared ? 1 : 0.95)
                        .opacity(appeared ? 1 : 0)
                        .animation(.spring(response: 0.4, dampingFraction: 0.85).delay(0.1), value: appeared)

                    // Active uploads
                    if appState.hasActiveUploads {
                        Divider()
                            .background(Color.krevoBorder)

                        activeUploadsSection
                    }

                    // Failed / cancelled uploads
                    if hasTerminalUploads {
                        terminalUploadsSection
                    }

                    // Recent completed
                    if !appState.recentCompleted.isEmpty {
                        Divider()
                            .background(Color.krevoBorder)

                        recentSection
                    }
                }
            }
            .scrollIndicators(.hidden)

            Divider()
                .background(Color.krevoBorder)

            // Footer
            footerView
        }
        .frame(width: 320)
        .onAppear {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                appeared = true
            }
        }
        .onDisappear {
            appeared = false
        }
    }

    // MARK: - Greeting + Weather

    private var greetingRow: some View {
        HStack(alignment: .center) {
            Text("Welcome")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.krevoPrimary)

            Spacer()

            if let weather = appState.weather {
                HStack(spacing: 4) {
                    Image(systemName: weather.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.krevoSecondary)
                    Text("\(weather.temperature)°F")
                        .font(.system(size: 13, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.krevoSecondary)
                }
            }
        }
    }

    // MARK: - Active Uploads

    private var activeUploadsSection: some View {
        VStack(spacing: 0) {
            ForEach(appState.activeUploads) { task in
                UploadProgressView(task: task)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Terminal Uploads (failed / cancelled)

    private var hasTerminalUploads: Bool {
        appState.uploadTasks.contains { task in
            if case .failed = task.state { return true }
            if case .cancelled = task.state { return true }
            return false
        }
    }

    private var terminalUploadsSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Issues")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.krevoTertiary)
                    .textCase(.uppercase)

                Spacer()

                Button("Clear") {
                    appState.clearCompleted()
                }
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 4)

            ForEach(terminalTasks) { task in
                UploadProgressView(task: task)
                    .padding(.horizontal, 12)
            }
        }
    }

    private var terminalTasks: [UploadTask] {
        appState.uploadTasks.filter { task in
            if case .failed = task.state { return true }
            if case .cancelled = task.state { return true }
            return false
        }
    }

    // MARK: - Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("RECENT")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.krevoTertiary)
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(appState.recentCompleted) { task in
                RecentCompletedRow(task: task)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 4)
    }

    // MARK: - Footer

    @ViewBuilder
    private func globalBannerView(_ banner: GlobalBanner) -> some View {
        switch banner {
        case .networkOffline:
            bannerCard(
                icon: "wifi.slash",
                title: "Offline",
                message: "Uploads pause until your connection returns.",
                color: Color(hex: "F59E0B")
            )

        case .authRequired:
            bannerCard(
                icon: "person.crop.circle.badge.exclamationmark",
                title: "Sign in again",
                message: "Your device session expired.",
                color: Color(hex: "EF4444")
            )

        case .quotaIssue(let message):
            bannerCard(
                icon: "externaldrive.badge.exclamationmark",
                title: "Storage limit reached",
                message: message,
                color: Color(hex: "F59E0B")
            )
        }
    }

    private func bannerCard(icon: String, title: String, message: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.krevoPrimary)

                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(color.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
    }

    private var completionBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(Color(hex: "22C55E"))

            Text(appState.completedFileName)
                .font(.system(size: 12))
                .foregroundStyle(Color.krevoSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Text("uploaded")
                .font(.system(size: 11))
                .foregroundStyle(Color.krevoTertiary)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(hex: "22C55E").opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: "22C55E").opacity(0.2), lineWidth: 1)
        )
        .onTapGesture {
            if let url = appState.completedShareURL {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url, forType: .string)
            }
            appState.showCompletionBanner = false
        }
    }

    private var footerView: some View {
        HStack {
            HStack(spacing: 4) {
                Text(appState.tier.capitalized)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.krevoSecondary)
            }

            Spacer()

            Button("Sign Out") {
                Task { await appState.signOut() }
            }
            .font(.system(size: 12))
            .foregroundStyle(Color.krevoTertiary)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}
