import SwiftUI

enum KrevoButtonStyle {
    case primary
    case secondary
    case destructive
}

struct KrevoButton: View {
    let title: String
    let style: KrevoButtonStyle
    let action: () -> Void
    var isLoading: Bool = false

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(textColor)
                } else {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(textColor)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(borderColor, lineWidth: hasBorder ? 1 : 0)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contentShape(Rectangle())
    }

    // MARK: - Style Computations

    private var textColor: Color {
        switch style {
        case .primary:
            return .white
        case .secondary:
            return Color(hex: "D4D4D8")
        case .destructive:
            return Color(hex: "EF4444")
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return isHovered ? Color(hex: "9B6FF6") : .krevoViolet
        case .secondary:
            return isHovered ? Color(hex: "27272A") : .clear
        case .destructive:
            return isHovered ? Color(hex: "EF4444").opacity(0.1) : .clear
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .clear
        case .secondary:
            return Color(hex: "3F3F46")
        case .destructive:
            return .clear
        }
    }

    private var hasBorder: Bool {
        style == .secondary
    }
}
