import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

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
        .frame(width: 320)
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
            ScrollView {
                VStack(spacing: 0) {
                    // Storage meter
                    StorageMeterView()
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 12)

                    Divider()
                        .background(Color.krevoBorder)

                    // Drop zone (always visible)
                    UploadDropZone(compact: appState.hasActiveUploads)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)

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
            .frame(maxHeight: 420)

            Divider()
                .background(Color.krevoBorder)

            // Footer
            footerView
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
