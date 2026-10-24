//
//  TaskStatusStyle.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26.
//
//  Colors for a task's status. One place to change if the asset roles differ.
//  ASSUMPTION: "<Name>_bg" / "Green" = tile fill, "<Name>" = accent (text, bar).
//
//  done:        accent = the "Green" asset (text, left bar, tick); fill = a light tint of it.
//  missed:      fill = "Missed_bg",      accent = "Missed"
//  rescheduled: fill = "Rescheduled_bg", accent = "Rescheduled"

import SwiftUI
import UIKit

enum TaskStatusStyle {
    case done, missed, rescheduled

    var fill: Color {
        switch self {
        case .done:        return TaskStatusStyle.pastel("Green", amount: 0.18)
        case .missed:      return TaskStatusStyle.pastel("Missed", amount: 0.14)   //NEW not in zip.
        case .rescheduled: return Color("Rescheduled_bg")
        }
    }

    var accent: Color {
        switch self {
        case .done:        return Color("Green")
        case .missed:      return Color("Missed")
        case .rescheduled: return Color("Rescheduled")
        }
    }

    /// A soft, OPAQUE tint of an asset color over the app background, so the hour
    /// lines don't show through the tile the way they would with `.opacity(...)`.
    /// `amount` = how much of the asset color (0.18 is a light pastel).
    private static func pastel(_ assetName: String, amount: CGFloat) -> Color {
        Color(uiColor: UIColor { traits in
            let base = (UIColor(named: assetName) ?? .systemGreen).resolvedColor(with: traits)
            let back = UIColor(Theme.bg).resolvedColor(with: traits)

            var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
            var kr: CGFloat = 0, kg: CGFloat = 0, kb: CGFloat = 0, ka: CGFloat = 0
            base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
            back.getRed(&kr, green: &kg, blue: &kb, alpha: &ka)

            return UIColor(red:   br * amount + kr * (1 - amount),
                           green: bg * amount + kg * (1 - amount),
                           blue:  bb * amount + kb * (1 - amount),
                           alpha: 1)
        })
    }
}
