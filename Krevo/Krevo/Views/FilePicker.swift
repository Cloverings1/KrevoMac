import AppKit

/// Presents an `NSOpenPanel` from a MenuBarExtra popover without dropping the
/// first click.
///
/// Calling `NSOpenPanel.runModal()` directly from the popover spins a nested
/// modal run loop before the MenuBarExtra window has finished resigning key,
/// so the panel opens in an inactive app and routes its first mouse-down to
/// activation instead of the file list. We activate the app first and use the
/// async `begin(completionHandler:)` form so there's no nested run loop
/// fighting the popover for focus.
@MainActor
enum FilePicker {
    static func presentUploadPicker(completion: @escaping @MainActor ([URL]) -> Void) {
        NSApp.activate()

        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.title = "Select Files or Folders to Upload"
        panel.level = .modalPanel

        panel.begin { response in
            Task { @MainActor in
                guard response == .OK else { return }
                completion(panel.urls)
            }
        }
    }
}
