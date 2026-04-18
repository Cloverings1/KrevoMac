import SwiftUI

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let scanner = Scanner(string: hex)
        var rgb: UInt64 = 0
        scanner.scanHexInt64(&rgb)
        self.init(
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255
        )
    }
}

// MARK: - Design Tokens (light mode — Krevo menu bar v2)

extension Color {
    // Surfaces
    static let krevoBg = Color(hex: "FBFBFC")
    static let krevoSecondaryBg = Color(hex: "F5F5F7")
    static let krevoCardBg = Color.white

    // Ink / text
    static let krevoPrimary = Color(hex: "0A0A0B")
    static let krevoSecondary = Color(hex: "3C3C43")
    static let krevoTertiary = Color(hex: "6E6E76")
    static let krevoQuaternary = Color(hex: "A1A1A8")

    // Lines
    static let krevoBorder = Color(hex: "E8E8EC")
    static let krevoBorderSoft = Color(hex: "F2F2F4")

    // Accent (baby blue)
    static let krevoAccent = Color(hex: "9EC5FE")
    static let krevoAccentDeep = Color(hex: "6AA4FB")
    static let krevoAccentSoft = Color(hex: "C7DCFE")
    static let krevoAccentInk = Color(hex: "1E3A8A")

    // Legacy aliases kept so existing views don't break until migrated.
    static var krevoViolet: Color { krevoAccentInk }
    static var krevoFuchsia: Color { krevoAccentDeep }

    // Status
    static let krevoGreen = Color(hex: "22C55E")
    static let krevoAmber = Color(hex: "F59E0B")
    static let krevoCoral = Color(hex: "F97316")
    static let krevoRed = Color(hex: "EF4444")
}
