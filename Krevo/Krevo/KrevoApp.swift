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
    private var rightClickMonitor: Any?

    private var hasRepliedToTerminate = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Abort active uploads so the server can release storage quota.
        Task { @MainActor in
            await AppState.shared.abortAllUploads()
            self.replyToTerminateOnce()
        }

        // Safety timeout — if cleanup takes longer than 5s, terminate anyway
        Task.detached { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            await MainActor.run {
                self?.replyToTerminateOnce()
            }
        }

        return .terminateLater
    }

    @MainActor
    private func replyToTerminateOnce() {
        guard !hasRepliedToTerminate else { return }
        hasRepliedToTerminate = true
        NSApp.reply(toApplicationShouldTerminate: true)
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

        installStatusItemRightClickMenu()
    }

    // MARK: - Status item right-click menu

    private func installStatusItemRightClickMenu() {
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let window = event.window,
                  String(describing: type(of: window)).contains("StatusBar")
            else { return event }
            self.presentStatusItemMenu(in: window)
            return nil
        }
    }

    private func presentStatusItemMenu(in window: NSWindow) {
        let menu = NSMenu()
        let quit = NSMenuItem(title: "Quit Krevo", action: #selector(quitFromStatusItem), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        let location = NSPoint(x: 0, y: window.frame.height)
        let mouseEvent = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
        if let mouseEvent {
            NSMenu.popUpContextMenu(menu, with: mouseEvent, for: window.contentView ?? NSView())
        }
    }

    @objc private func quitFromStatusItem() {
        NSApp.terminate(nil)
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
