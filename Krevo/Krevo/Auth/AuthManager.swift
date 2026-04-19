import AuthenticationServices
import Foundation
import os

@Observable
@MainActor
final class AuthManager {
    static let shared = AuthManager()

    var isAuthenticating = false
    var error: String?

    /// Retained so ARC cannot deallocate the session before the callback fires.
    private var currentSession: ASWebAuthenticationSession?
    private var pendingContinuation: CheckedContinuation<String?, Never>?
    private var pendingChallenge: CallbackChallenge?

    func signIn() async -> String? {
        guard !isAuthenticating else { return nil }

        isAuthenticating = true
        error = nil

        defer {
            isAuthenticating = false
            currentSession = nil
            pendingContinuation = nil
            pendingChallenge = nil
        }

        return await withCheckedContinuation { continuation in
            pendingContinuation = continuation
            let challenge = CallbackChallenge()
            pendingChallenge = challenge

            let session = ASWebAuthenticationSession(
                url: authURL(for: challenge),
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
        guard validateCallback(url) else {
            error = "Sign-in response could not be verified. Retry the secure sign-in flow."
            finishSignIn(with: nil)
            return true
        }

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

    private func authURL(for challenge: CallbackChallenge) -> URL {
        guard var components = URLComponents(url: KrevoConstants.authURL, resolvingAgainstBaseURL: false) else {
            return KrevoConstants.authURL
        }

        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "state", value: challenge.state))
        queryItems.append(URLQueryItem(name: "nonce", value: challenge.nonce))
        components.queryItems = queryItems
        return components.url ?? KrevoConstants.authURL
    }

    private func validateCallback(_ url: URL) -> Bool {
        guard let challenge = pendingChallenge,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }

        let returnedState = components.queryItems?.first(where: { $0.name == "state" })?.value
        let returnedNonce = components.queryItems?.first(where: { $0.name == "nonce" })?.value

        // The web flow may not echo state/nonce yet. When absent, fall back to trusting
        // the krevo:// scheme (only the system can deliver to a registered scheme handler).
        // When either is returned, both must match the challenge we issued.
        if returnedState == nil && returnedNonce == nil {
            KrevoConstants.authLogger.warning("Auth callback missing state/nonce — accepting on scheme trust")
            return true
        }

        return returnedState == challenge.state && returnedNonce == challenge.nonce
    }

    private func token(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == "token" })?.value
        else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (32...512).contains(trimmed.count),
              trimmed.unicodeScalars.allSatisfy({ AuthManager.tokenCharset.contains($0) })
        else {
            return nil
        }
        return trimmed
    }

    private static let tokenCharset: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "._-")
        return set
    }()
}

private struct CallbackChallenge {
    let state = UUID().uuidString.lowercased()
    let nonce = UUID().uuidString.lowercased()
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
