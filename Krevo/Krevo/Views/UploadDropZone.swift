import SwiftUI
import UniformTypeIdentifiers

struct UploadDropZone: View {
    @Environment(AppState.self) private var appState
    @State private var isTargeted = false
    var compact: Bool = false

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: compact ? 18 : 24, weight: .light))
                .foregroundStyle(isTargeted ? Color.krevoViolet : Color.krevoTertiary)

            VStack(spacing: 2) {
                Text("Drop files here")
                    .font(.system(size: compact ? 12 : 13, weight: .medium))
                    .foregroundStyle(isTargeted ? Color.krevoPrimary : Color.krevoSecondary)

                Text("or click to browse")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.krevoTertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: compact ? 72 : 110)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isTargeted ? Color.krevoViolet.opacity(0.08) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    isTargeted ? Color.krevoViolet : Color.krevoBorder,
                    style: StrokeStyle(
                        lineWidth: 1,
                        dash: isTargeted ? [] : [6, 4]
                    )
                )
        )
        .scaleEffect(isTargeted ? 1.02 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isTargeted)
        .contentShape(Rectangle())
        .onTapGesture {
            openFilePicker()
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers)
            return true
        }
        .accessibilityLabel("Drop zone")
        .accessibilityHint("Drop files to upload, or activate to browse and select files")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - File Picker

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.title = "Select Files to Upload"

        if panel.runModal() == .OK {
            appState.startUpload(urls: panel.urls)
        }
    }

    // MARK: - Drop Handler

    private func handleDrop(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }

            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                defer { group.leave() }

                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil, isAbsolute: true)
                else { return }

                // Only accept files, not directories
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                appState.startUpload(urls: urls)
            }
        }
    }
}
