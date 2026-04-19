import SwiftUI

struct UploadDropZone: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    var compact: Bool = false

    private var zoneHeight: CGFloat { compact ? 72 : 108 }
    private var cornerRadius: CGFloat { compact ? 14 : 16 }
    private var borderColor: Color {
        isHovered ? Color.krevoAccentDeep.opacity(0.95) : Color.krevoAccentInk.opacity(0.45)
    }
    private var backgroundFill: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.krevoAccent.opacity(isHovered ? 0.24 : 0.12),
                Color.krevoSecondaryBg.opacity(isHovered ? 0.92 : 0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // Drag-and-drop is handled panel-wide in MenuBarView, so this view is a
    // click-to-browse affordance only — attaching an onDrop here would compete
    // with the outer drop target and fire the upload twice.
    var body: some View {
        VStack(spacing: compact ? 7 : 10) {
            Image(systemName: "arrow.up.doc")
                .font(.system(size: compact ? 18 : 22, weight: .light))
                .foregroundStyle(isHovered ? Color.krevoAccentInk : Color.krevoSecondary)

            Text("Drop files or click to browse")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovered ? Color.krevoPrimary : Color.krevoSecondary)

            Text("Click anywhere in this box or drag files onto it")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isHovered ? Color.krevoAccentInk.opacity(0.88) : Color.krevoTertiary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, compact ? 12 : 16)
        .frame(maxWidth: .infinity)
        .frame(height: zoneHeight)
        .background(
            RoundedRectangle(cornerRadius: cornerRadius)
                .fill(backgroundFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    borderColor,
                    style: StrokeStyle(lineWidth: isHovered ? 1.8 : 1.4, dash: [5, 4])
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius - 4)
                .stroke(
                    Color.white.opacity(isHovered ? 0.7 : 0.45),
                    style: StrokeStyle(lineWidth: 1, lineCap: .round, dash: [1, 6])
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
        FilePicker.presentUploadPicker { urls in
            appState.startUpload(urls: urls)
        }
    }

}
