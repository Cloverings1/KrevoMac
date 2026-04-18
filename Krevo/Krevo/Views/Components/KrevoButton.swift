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
            .padding(.vertical, 7)
            .foregroundStyle(textColor)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
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

    private var textColor: Color {
        switch style {
        case .primary:
            return .krevoAccentInk
        case .secondary:
            return .krevoSecondary
        case .destructive:
            return .krevoRed
        }
    }

    private var background: Color {
        switch style {
        case .primary:
            return isHovered ? .krevoAccentSoft : Color.krevoAccent.opacity(0.35)
        case .secondary:
            return isHovered ? .krevoSecondaryBg : .clear
        case .destructive:
            return isHovered ? Color.krevoRed.opacity(0.08) : .clear
        }
    }

    private var borderColor: Color {
        switch style {
        case .primary:
            return .clear
        case .secondary:
            return .krevoBorder
        case .destructive:
            return .clear
        }
    }

    private var hasBorder: Bool {
        style == .secondary
    }
}
