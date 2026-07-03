//
//  Theme.swift
//  RelayBack
//
//  S13a — the design-handoff tokens (colors, radii, brand gradient) recreated natively so the
//  SwiftUI surfaces match `design_handoff_relayback_app/`. Plain constants — not unit-tested;
//  verified by the Previews that consume them. UI text uses the system font (SF Pro Text) and
//  SF Mono for commands / ids / output / countdowns, per the handoff's macOS-native mapping.
//

import SwiftUI

enum Theme {
    // MARK: Surfaces
    static let popoverSurface = Color(hex: 0xF4F5F9)
    static let settingsWindow = Color(hex: 0xECECEC)
    static let settingsContent = Color(hex: 0xF4F4F6)
    static let settingsSidebar = Color(hex: 0xE3E3E6)
    static let card = Color.white
    static let terminal = Color(hex: 0x0F1320)

    // MARK: Text
    static let textPrimary = Color(hex: 0x1C1C1E)
    static let textSecondary = Color(hex: 0x8A8A8E)
    static let textTertiary = Color(hex: 0xA0A0A6)

    // MARK: Accents / state
    static let accent = Color(hex: 0x0A6CFF)
    static let armedGreen = Color(hex: 0x34C759)
    static let armedGreenText = Color(hex: 0x248A3D)
    static let terminalGreen = Color(hex: 0x7EE0A0)
    static let disarmedDot = Color(hex: 0x8E8E93)
    static let disarmedText = Color(hex: 0x5B5B60)
    static let warning = Color(hex: 0xFF9F0A)
    static let warningText = Color(hex: 0xB76E00)
    static let danger = Color(hex: 0xFF3B30)

    // MARK: Dividers / hairlines
    static let divider = Color.black.opacity(0.07)
    static let cardBorder = Color.black.opacity(0.06)

    // MARK: Brand gradient (155° #4f6bff → #2aa9c9), used for the app glyph.
    static let brandGradient = LinearGradient(
        colors: [Color(hex: 0x4F6BFF), Color(hex: 0x2AA9C9)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    // MARK: Radii
    enum Radius {
        static let popover: CGFloat = 14
        static let window: CGFloat = 12
        static let card: CGFloat = 10
        static let chip: CGFloat = 7
        static let pill: CGFloat = 20
    }

    // MARK: Popover metrics
    static let popoverWidth: CGFloat = 368
}

extension MenuBarStatus.PillStyle {
    /// The pill's foreground (text/dot) color for this state.
    var foreground: Color {
        switch self {
        case .armed: return Theme.armedGreenText
        case .disarmed: return Theme.disarmedText
        }
    }

    /// The pill's dot color for this state.
    var dot: Color {
        switch self {
        case .armed: return Theme.armedGreen
        case .disarmed: return Theme.disarmedDot
        }
    }

    /// The pill's translucent background fill for this state.
    var background: Color {
        switch self {
        case .armed: return Theme.armedGreen.opacity(0.16)
        case .disarmed: return Color(hex: 0x787880).opacity(0.16)
        }
    }
}

extension Color {
    /// Builds a `Color` from a 24-bit `0xRRGGBB` literal — keeps the token table above readable.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
