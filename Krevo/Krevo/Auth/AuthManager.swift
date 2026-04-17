import AuthenticationServices

@Observable
@MainActor
final class AuthManager {
    static let shared = AuthManager()

    var isAuthenticating = false
    var error: String?

    /// Retained so ARC cannot deallocate the session before the callback fires.
    private var currentSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<String?, Never>?

    func signIn() async -> String? {
        guard !isAuthenticating else { return nil }

        isAuthenticating = true
        error = nil

        defer {
            isAuthenticating = false
            currentSession = nil
            pendingContinuation = nil
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation

            let session = ASWebAuthenticationSession(
                url: KrevoConstants.authURL,
                callbackURLScheme: KrevoConstants.urlScheme
            ) { [weak self] callbackURL, error in
                Task { @MainActor [weak self] in
                    self?.handleSessionCompletion(callbackURL: callbackURL, error: error)
                }
            }

            self.currentSession = session
            session.presentationContextProvider = MacAuthPresentationProvider.shared
            session.prefersEphemeralWebBrowserSession = false

            guard session.start() else {
                self.error = "Could not start the secure sign-in session."
                self.finishSignIn(with: nil)
                return
            }
        }
    }

    func handleCallbackURL(_ url: URL) -> Bool {
        guard pendingContinuation != nil else { return false }
        guard url.scheme == KrevoConstants.urlScheme, url.host == "auth" else { return false }

        guard let token = token(from: url) else {
            error = "Failed to get authentication token."
            finishSignIn(with: nil)
            return true
        }

        error = nil
        finishSignIn(with: token)
        return true
    }

    private func handleSessionCompletion(callbackURL: URL?, error: Error?) {
        guard pendingContinuation != nil else { return }

        if let error {
            let nsError = error as NSError
            if nsError.domain == ASWebAuthenticationSessionError.errorDomain,
               nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                finishSignIn(with: nil)
                return
            }

            self.error = error.localizedDescription
            finishSignIn(with: nil)
            return
        }

        guard let callbackURL else {
            self.error = "Failed to get authentication token."
            finishSignIn(with: nil)
            return
        }

        if !handleCallbackURL(callbackURL) {
            self.error = "Failed to get authentication token."
            finishSignIn(with: nil)
        }
    }

    private func finishSignIn(with token: String?) {
        guard let continuation = pendingContinuation else { return }
        pendingContinuation = nil
        continuation.resume(returning: token)
    }

    private func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        return components.queryItems?.first(where: { $0.name == "token" })?.value
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
