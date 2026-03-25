import SwiftUI

@main
struct KrevoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var appState: AppState { AppState.shared }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            if appState.hasActiveUploads {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolEffect(.pulse)
                    .accessibilityLabel("Krevo — Upload in progress")
            } else {
                Image(systemName: "arrow.up.circle")
                    .accessibilityLabel("Krevo — Upload files")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

// Handle krevo:// URL scheme via Apple Events (MenuBarExtra doesn't support .onOpenURL)
class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        // Abort active uploads so the server can release storage quota.
        // Bridge async cleanup to the synchronous termination callback with a short timeout.
        let semaphore = DispatchSemaphore(value: 0)
        Task { @MainActor in
            await AppState.shared.abortAllUploads()
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Run the one-time auth check at app launch
        Task { @MainActor in
            await AppState.shared.initialize()
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == KrevoConstants.urlScheme,
              url.host == "auth",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return }

        // AppState.shared is always available — no optional chaining needed
        Task { @MainActor in
            await AppState.shared.signIn(token: token)
        }
    }
}
