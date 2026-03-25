import AuthenticationServices

@Observable
final class AuthManager {
    var isAuthenticating = false
    var error: String?

    /// Retained so ARC cannot deallocate the session before the callback fires.
    private var currentSession: ASWebAuthenticationSession?

    @MainActor
    func signIn() async -> String? {
        isAuthenticating = true
        error = nil

        defer {
            isAuthenticating = false
            currentSession = nil
        }

        return await withCheckedContinuation { continuation in
            let session = ASWebAuthenticationSession(
                url: KrevoConstants.authURL,
                callbackURLScheme: KrevoConstants.urlScheme
            ) { [weak self] callbackURL, error in
                if let error {
                    // User cancellation is not an error worth showing
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(returning: nil)
                        return
                    }

                    self?.error = error.localizedDescription
                    continuation.resume(returning: nil)
                    return
                }

                guard let callbackURL,
                      let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
                      let token = components.queryItems?.first(where: { $0.name == "token" })?.value
                else {
                    self?.error = "Failed to get authentication token"
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: token)
            }

            // Store a strong reference before starting
            self.currentSession = session

            session.presentationContextProvider = MacAuthPresentationProvider.shared
            session.prefersEphemeralWebBrowserSession = false
            session.start()
        }
    }
}

// MARK: - Presentation Context

final class MacAuthPresentationProvider: NSObject, ASWebAuthenticationPresentationContextProviding, @unchecked Sendable {
    static let shared = MacAuthPresentationProvider()

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        NSApplication.shared.keyWindow
            ?? NSApplication.shared.windows.first(where: { $0.isVisible })
            ?? NSApplication.shared.windows.first
            ?? NSWindow()
    }
}
