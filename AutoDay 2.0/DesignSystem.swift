//
//  DesignSystem.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  Theme, Color(hex:), PastelColor, SheetGlass, GlassCapsule

import SwiftUI

// MARK: - Theme

enum Theme {
    static let primary   = Color(hex: "#7C5CD6")
    static let secondary = Color(hex: "#EDE7FB")
    static let rescheduleRed  = Color(hex: "#f56469")
    static let rescheduleText = Color(hex: "#E5484D")
    static let bg        = Color(hex: "#FBFAFC")
    static let labelGray = Color(hex: "#9E9E9E")
    static let divider   = Color(hex: "#E0E0E0")
    static let doneGreen = Color(hex: "#2FA36B")
    static let hourHeight: CGFloat = 70
    static let labelWidth: CGFloat = 52
    static let lineInset: CGFloat = 8   // add to Theme
}

// MARK: - Pastel palette

enum PastelColor: CaseIterable {
    case sky, cyan, pink, orchid, indigo, sand, slate, peach, mauve, steel, navy, plum, clay, fuchsia

    /// Background fill – matches the asset named exactly after the case (e.g. "Sky")
    var fill: Color {
        switch self {
        case .sky:     return Color("Sky")
        case .cyan:    return Color("Cyan")
        case .pink:    return Color("Pink")
        case .orchid:  return Color("Orchid")
        case .indigo:  return Color("Indigo")
        case .sand:    return Color("Sand")
        case .slate:   return Color("Slate")
        case .peach:   return Color("Peach")
        case .mauve:   return Color("Mauve")
        case .steel:   return Color("Steel")
        case .navy:    return Color("Navy")
        case .plum:    return Color("Plum")
        case .clay:    return Color("Clay")
        case .fuchsia: return Color("Fuchsia")
        }
    }

    /// Text / accent colour – matches the asset named "ColorName_Accent" (e.g. "Sky_Accent")
    var text: Color {
        switch self {
        case .sky:     return Color("Sky_Accent")
        case .cyan:    return Color("Cyan_Accent")
        case .pink:    return Color("Pink_Accent")
        case .orchid:  return Color("Orchid_Accent")
        case .indigo:  return Color("Indigo_Accent")
        case .sand:    return Color("Sand_Accent")
        case .slate:   return Color("Slate_Accent")
        case .peach:   return Color("Peach_Accent")
        case .mauve:   return Color("Mauve_Accent")
        case .steel:   return Color("Steel_Accent")
        case .navy:    return Color("Navy_Accent")
        case .plum:    return Color("Plum_Accent")
        case .clay:    return Color("Clay_Accent")
        case .fuchsia: return Color("Fuchsia_Accent")
        }
    }
}

// MARK: - Color hex helper

extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: .init(charactersIn: "#"))
        var val: UInt64 = 0
        Scanner(string: h).scanHexInt64(&val)
        let r = Double((val >> 16) & 0xFF) / 255
        let g = Double((val >> 8)  & 0xFF) / 255
        let b = Double(val & 0xFF)         / 255
        self.init(red: r, green: g, blue: b)
    }
}

// MARK: - Glass modifiers

struct SheetGlass: ViewModifier {
    func body(content: Content) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 24,
                                           topTrailingRadius: 24,
                                           style: .continuous)
        if #available(iOS 26, *) {
            content.background {
                Color.clear
                    .glassEffect(.regular, in: shape)
                    .ignoresSafeArea(edges: .bottom)
            }
        } else {
            content.background {
                shape
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 20, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
    }
}

struct GlassCapsule: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
        }
    }
}
