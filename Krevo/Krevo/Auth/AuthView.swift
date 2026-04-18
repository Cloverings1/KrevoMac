import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @State private var authManager = AuthManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            // Mark
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.krevoAccent.opacity(0.5), Color.krevoAccent],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .frame(width: 56, height: 56)
                    .shadow(color: Color.krevoAccentInk.opacity(0.15), radius: 16, y: 6)
                Image(systemName: "arrow.up")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.krevoAccentInk)
            }
            .padding(.bottom, 16)

            VStack(spacing: 4) {
                Text("Krevo")
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.5)
                    .foregroundStyle(Color.krevoPrimary)

                Text("Upload files at full speed")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.krevoTertiary)
            }

            Spacer().frame(height: 28)

            if authManager.isAuthenticating {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color.krevoAccentInk)
                    .frame(height: 36)
            } else {
                KrevoButton(title: primaryButtonTitle, style: .primary) {
                    if shouldRetryStoredSession {
                        Task { await appState.checkAuth() }
                    } else {
                        Task {
                            if let token = await authManager.signIn() {
                                await appState.signIn(token: token)
                            }
                        }
                    }
                }
                .frame(maxWidth: 220)
            }

            if let error = authManager.error ?? appState.authMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.krevoRed.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .frame(maxWidth: 240)
            }

            Spacer()

            Text("krevo.io")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.krevoQuaternary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color.krevoBg
                RadialGradient(
                    colors: [Color.krevoAccent.opacity(0.18), .clear],
                    center: .init(x: 0.5, y: 0.15),
                    startRadius: 0,
                    endRadius: 220
                )
            }
        )
    }

    private var shouldRetryStoredSession: Bool {
        appState.hasStoredSession && appState.authMessage != nil && !appState.isAuthenticated
    }

    private var primaryButtonTitle: String {
        shouldRetryStoredSession ? "Retry connection" : "Connect account"
    }
}
