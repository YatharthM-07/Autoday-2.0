//
//  TimelineSupport.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  Metrics constants and helpers (kPPM, snappedMinutes, hm,etc.) + ScrollBox, ScrollViewFinder, ScrollOffsetKey

import SwiftUI
import UIKit

// MARK: - Drag/Drop constants

/// Points per minute on the timeline  (hourHeight = 70 → 70/60 ≈ 1.167 pt/min)
let kPPM: CGFloat = Theme.hourHeight / 60
let kSnapMinutes: Int = 15
let kTimelineStart: Int = 7   // 07:00
let kTimelineEnd:   Int = 23  // 23:00
let kTimelineStartMinutes: Int = kTimelineStart * 60
let kTimelineEndMinutes:   Int = kTimelineEnd   * 60

/// Named coordinate space attached to the (stationary) timeline ScrollView.
let kTimelineSpace = "timelineScroll"

// MARK: - Drag/Drop helpers

/// Snap `raw` minutes to the nearest `kSnapMinutes` boundary.
func snappedMinutes(_ raw: Int) -> Int {
    let half = kSnapMinutes / 2
    return ((raw + half) / kSnapMinutes) * kSnapMinutes
}

func minutesToHours(_ m: Int)    -> Double { Double(m) / 60.0 }
func hoursToMinutes(_ h: Double) -> Int    { Int(h * 60) }

/// Top-offset (pts) inside the timeline scroll content for a given fractional hour.
func topOffsetForHour(_ hour: Double) -> CGFloat {
    CGFloat(hour - Double(kTimelineStart)) * Theme.hourHeight + Theme.lineInset + 1
}

// MARK: - Helpers

func hm(_ hour: Double) -> String {
    let h = Int(hour)
    let m = Int((hour - Double(h)) * 60)
    return String(format: "%02d:%02d", h, m)
}

// MARK: - Scroll support

/// Holds the timeline's scroll offset without triggering a re-render on every scroll frame.
final class ScrollBox {
    var y: CGFloat = 0                    // offset from the preference tracker (used for sheet drops)
    weak var sv: UIScrollView?            // the timeline's underlying scroll view (for auto-scroll)
    var velocity: CGFloat = 0             // auto-scroll speed in pt/s (+ = down)

    // Live-drag bookkeeping
    var dragging = false
    var dragStartY: CGFloat = 0           // scroll offset when the drag began
    var lastTranslation: CGFloat = 0      // finger's vertical travel on screen
    var dragStartHour: Double = 0
    var dragDuration: Double = 0
    var lastLocation: CGPoint = .zero    // ← add: finger's last global position during a drag
    var timelineTop: CGFloat = 0         // ← add: global minY of the timeline (above this = header area)

    var currentY: CGFloat { sv?.contentOffset.y ?? y }
    /// How far the content has scrolled since the drag began.
    var scrollDelta: CGFloat { currentY - dragStartY }
    
    var startLocation: CGPoint = .zero    // finger position when the drag began
}

/// Finds the UIScrollView that hosts the SwiftUI ScrollView so we can scroll it programmatically.
struct ScrollViewFinder: UIViewRepresentable {
    let onFound: (UIScrollView) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            var v: UIView? = uiView
            while let cur = v, !(cur is UIScrollView) { v = cur.superview }
            if let sv = v as? UIScrollView { onFound(sv) }
        }
    }
}

// MARK: - Scroll Offset Preference Key

struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
