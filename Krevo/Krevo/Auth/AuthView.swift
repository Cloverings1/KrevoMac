import SwiftUI

struct AuthView: View {
    @Environment(AppState.self) private var appState
    @State private var authManager = AuthManager()

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
                KrevoButton(title: "Connect Account", style: .primary) {
                    Task {
                        if let token = await authManager.signIn() {
                            await appState.signIn(token: token)
                        }
                    }
                }
                .frame(maxWidth: 200)
            }

            if let error = authManager.error {
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
}
