import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @State private var authManager = AuthManager.shared

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 6) {
                Text("Krevo")
                    .font(.system(size: 34, weight: .thin))
                    .foregroundStyle(Color(hex: "FAFAFA"))

                Text("Upload files at full speed")
                    .font(.system(size: 14))
                    .foregroundStyle(Color(hex: "A1A1AA"))
            }

            Spacer().frame(height: 32)

            if authManager.isAuthenticating {
                ProgressView()
                    .controlSize(.small)
                    .tint(Color(hex: "8B5CF6"))
                    .frame(height: 36)
            } else {
                KrevoButton(title: primaryButtonTitle, style: .primary) {
                    if shouldRetryStoredSession {
                        Task {
                            await appState.checkAuth()
                        }
                    } else {
                        Task {
                            if let token = await authManager.signIn() {
                                await appState.signIn(token: token)
                            }
                        }
                    }
                }
                .frame(maxWidth: 200)
            }

            if let error = authManager.error ?? appState.authMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.top, 12)
                    .frame(maxWidth: 220)
            }

            Spacer()

            Text("krevo.io")
                .font(.system(size: 11))
                .foregroundStyle(Color(hex: "52525B"))
                .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private var shouldRetryStoredSession: Bool {
        appState.hasStoredSession && appState.authMessage != nil && !appState.isAuthenticated
    }

    private var primaryButtonTitle: String {
        shouldRetryStoredSession ? "Retry Connection" : "Connect Account"
    }
}
