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

// MARK: - Design Tokens

extension Color {
    static let krevoBg = Color.black
    static let krevoSecondaryBg = Color(hex: "0A0A0A")
    static let krevoCardBg = Color(hex: "111111")

    static let krevoPrimary = Color(hex: "FAFAFA")
    static let krevoSecondary = Color(hex: "A1A1AA")
    static let krevoTertiary = Color(hex: "71717A")

    static let krevoViolet = Color(hex: "8B5CF6")
    static let krevoFuchsia = Color(hex: "D946EF")
    static let krevoAmber = Color(hex: "F59E0B")
    static let krevoCoral = Color(hex: "F97316")
    static let krevoRed = Color(hex: "EF4444")

    static let krevoBorder = Color(hex: "27272A")
}
