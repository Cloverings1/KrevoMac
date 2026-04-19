import SwiftUI
import AppKit
import UserNotifications

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
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Abort active uploads so the server can release storage quota.
        // Use async termination to avoid blocking with DispatchSemaphore.
        Task { @MainActor in
            await AppState.shared.abortAllUploads()
            NSApp.reply(toApplicationShouldTerminate: true)
        }

        // Safety timeout — if cleanup takes longer than 5s, terminate anyway
        Task.detached {
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }

        return .terminateLater
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        // Request notification permission (alert only, no sound)
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { _, _ in }

        // Run the one-time auth check at app launch
        Task { @MainActor in
            await AppState.shared.initialize()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            await AppState.shared.applicationDidBecomeActive()
        }
    }

    // MARK: - Notification Delegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    // MARK: - URL Scheme

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, withReplyEvent replyEvent: NSAppleEventDescriptor) {
        guard let urlString = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: urlString),
              url.scheme == KrevoConstants.urlScheme,
              url.host == "auth"
        else { return }

        Task { @MainActor in
            _ = AuthManager.shared.handleCallbackURL(url)
        }
    }
}
