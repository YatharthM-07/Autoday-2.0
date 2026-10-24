//
//  MissedAlert.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26. 
//
//  Missed tasks: the rule, the one-time alert (scroll, shake, red, banner) and the top overlay.
//  New file, not in zip. All colours come from TaskStatusStyle.missed (asset tints).
//  NEW not in zip.

import SwiftUI
import UIKit

// MARK: - Rule

/// Reads the backend's missed flag (`isMissedRow`), plus the 15-minute rule for the gap before the sweep runs.
enum MissedRule {
    /// A task counts as missed this long after its end time.
    static let grace: TimeInterval = 15 * 60
    
    static func endDate(of task: TimelineTask, calendar: Calendar = .current) -> Date? {
        calendar.date(byAdding: .minute,
                      value: Int((task.endHour * 60).rounded()),
                      to: calendar.startOfDay(for: task.date))
    }

    /// Takes `now` so it can be unit tested without the clock.
    static func isMissed(_ task: TimelineTask, now: Date, calendar: Calendar = .current) -> Bool {
        guard !task.isDone else { return false }
        if task.isMissedRow { return true }          // the scheduler already marked this slot missed
        guard let end = endDate(of: task, calendar: calendar) else { return false }
        return now >= end.addingTimeInterval(grace)
    }
}

// MARK: - State

struct MissedBanner: Identifiable {
    let id = UUID()
    let text: String
    let date: Date          // day of the earliest newly missed task
    let hour: Double        // its start, used to scroll there when the banner is tapped
}

struct MissedTracker {
    /// Alert already triggered for these tasks (so it never replays).
    var seen: Set<UUID> = []
    /// Tasks currently shown in the missed colours.
    var revealed: Set<UUID> = []
    /// Tasks mid-shake.
    var shaking: Set<UUID> = []
    var banner: MissedBanner? = nil
}

// MARK: - Shake

/// Horizontal shake that settles back to 0. Drive `progress` 0 → 1.
struct ShakeEffect: GeometryEffect {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let x = 9 * (1 - progress) * sin(progress * .pi * 7)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

// MARK: - TimelineView glue

extension TimelineView {

    /// Red only after the alert has revealed it, and only while it is still missed.
    func isMissedDisplayed(_ task: TimelineTask) -> Bool {
        missedTracker.revealed.contains(task.id)
            && MissedRule.isMissed(task, now: Date(), calendar: calendar)
    }

    /// Call on app open (`scroll: true`) and on the 30 s timer (`scroll: false`).
    func checkMissed(scroll: Bool) {
        store.tick()          // scheduler sweep: day rollover, snooze expiry, missed → re-plan
        let now = Date()
        let missed = store.tasks.filter { MissedRule.isMissed($0, now: now, calendar: calendar) }
        let ids    = Set(missed.map(\.id))

        // A task that is no longer missed (done, snoozed, moved) can alert again later.
        missedTracker.seen.formIntersection(ids)
        missedTracker.revealed.formIntersection(ids)

        let fresh = missed.filter { !missedTracker.seen.contains($0.id) }
        guard !fresh.isEmpty else { return }
        missedTracker.seen.formUnion(fresh.map(\.id))

        let here      = fresh.filter {  calendar.isDate($0.date, inSameDayAs: selectedDate) }
        let elsewhere = fresh.filter { !calendar.isDate($0.date, inSameDayAs: selectedDate) }
        missedTracker.revealed.formUnion(elsewhere.map(\.id))   // other days: red, no motion

        var delay = 0.15
        if scroll, let target = here.min(by: { $0.startHour < $1.startHour }) {
            if scrollTimeline(toHour: target.startHour, force: false) { delay = 0.6 }
        }

        let first = fresh.min { ($0.date, $0.startHour) < ($1.date, $1.startHour) }
        let banner = first.map {
            MissedBanner(text: fresh.count == 1 ? "1 task missed" : "\(fresh.count) tasks missed",
                         date: $0.date, hour: $0.startHour)
        }
        let hereIDs = here.map(\.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            revealMissed(hereIDs, banner: banner)
        }
    }

    /// Turns the tiles red, shakes them once, shows the banner. One haptic for the whole batch.
    func revealMissed(_ ids: [UUID], banner: MissedBanner?) {
        withAnimation(.easeInOut(duration: 0.3)) {
            missedTracker.revealed.formUnion(ids)
            missedTracker.banner = banner
        }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        StatusSound.play(.missed)

        if !UIAccessibility.isReduceMotionEnabled, !ids.isEmpty {
            missedTracker.shaking.formUnion(ids)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                missedTracker.shaking.subtract(ids)
            }
        }

        if let banner {
            UIAccessibility.post(notification: .announcement, argument: banner.text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
                if missedTracker.banner?.id == banner.id {
                    withAnimation(.easeInOut) { missedTracker.banner = nil }
                }
            }
        }
    }

    /// Scrolls the timeline so `hour` is comfortably in view. Returns true if it scrolled.
    @discardableResult
    func scrollTimeline(toHour hour: Double, force: Bool) -> Bool {
        guard let sv = scrollBox.sv else { return false }
        let y    = topOffsetForHour(hour)
        let off  = sv.contentOffset.y
        let comfortable = y >= off + 20 && y <= off + sv.bounds.height - 200   // bottom sheet covers the lower part
        guard force || !comfortable else { return false }

        let minY   = -sv.adjustedContentInset.top
        let maxY   = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
        let target = min(max(y - sv.bounds.height * 0.3, minY), maxY)
        sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: true)
        return true
    }

    /// Banner tap: go to the earliest newly missed task.
    func jumpToMissed(_ banner: MissedBanner) {
        withAnimation(.easeInOut) { missedTracker.banner = nil }
        if !calendar.isDate(banner.date, inSameDayAs: selectedDate) {
            withAnimation(.easeInOut(duration: 0.25)) {
                selectedDate = calendar.startOfDay(for: banner.date)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            scrollTimeline(toHour: banner.hour, force: true)
        }
    }

    // MARK: Views

//    @ViewBuilder
//    var missedBanner: some View {
//        if let banner = missedTracker.banner {
//            let style = TaskStatusStyle.missed
//            Button { jumpToMissed(banner) } label: {
//                Label(banner.text, systemImage: "exclamationmark.circle.fill")
//                    .font(.footnote.weight(.semibold))
//                    .foregroundStyle(style.accent)
//                    .padding(.horizontal, 14)
//                    .frame(height: 36)
//                    .background(style.fill, in: Capsule())
//                    .background(Theme.bg, in: Capsule())      // keeps it opaque over the hour lines
//                    .overlay(Capsule().strokeBorder(style.accent.opacity(0.35), lineWidth: 1))
//            }
//            .buttonStyle(.plain)
//            .padding(.top, 8)
//            .accessibilityHint("Shows the first missed task")
//            .transition(.move(edge: .top).combined(with: .opacity))
//        }
//    }
//
//    /// Pinned to the visible top of the timeline (not the scrolling content).
//    @ViewBuilder
//    var timelineTopOverlay: some View {
//        VStack(spacing: 8) {
//            missedBanner
//            noSlotCapsule
//        }
//    }
    
    @ViewBuilder
    var missedBanner: some View {
        if let banner = missedTracker.banner {
            let accent = TaskStatusStyle.missed.accent
            let shape  = RoundedRectangle(cornerRadius: 14, style: .continuous)
            Button { jumpToMissed(banner) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .background(accent.opacity(0.14), in: Circle())
                    Text(banner.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Text("View")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 12)
                .frame(height: 48)
                .background(Color(uiColor: .systemBackground), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHint("Shows the first missed task")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Pinned to the visible top of the timeline (not the scrolling content).
    @ViewBuilder
    var timelineTopOverlay: some View {
        noSlotCapsule
    }
}
