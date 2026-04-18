import SwiftUI
import UniformTypeIdentifiers
import os

struct UploadDropZone: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    var compact: Bool = false

    // Drag-and-drop is handled panel-wide in MenuBarView, so this view is a
    // click-to-browse affordance only — attaching an onDrop here would compete
    // with the outer drop target and fire the upload twice.
    var body: some View {
        VStack(spacing: compact ? 6 : 8) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: compact ? 16 : 20, weight: .light))
                .foregroundStyle(isHovered ? Color.krevoAccentInk : Color.krevoTertiary)

            Text("Drop files or click to browse")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.krevoPrimary : Color.krevoSecondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 56 : 80)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isHovered ? Color.krevoSecondaryBg : Color.krevoSecondaryBg.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    Color.krevoBorder,
                    style: StrokeStyle(lineWidth: 1, dash: [6, 4])
                )
        )
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture { openFilePicker() }
        .accessibilityLabel("Browse files to upload")
        .accessibilityHint("Opens a file picker")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - File Picker

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.title = "Select Files or Folders to Upload"

        if panel.runModal() == .OK {
            appState.startUpload(urls: panel.urls)
        }
    }

}
