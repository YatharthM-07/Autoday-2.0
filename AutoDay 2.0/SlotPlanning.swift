//
//  SlotPlanning.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  Slot planning contract + mock planner, and the drag UI that draws it:
//  placeholders (whole-fit / split) and the floating "picked-up" tile.
//
//  BACKEND: replace `MockSlotPlanner` with a type that calls the real scheduler.


import SwiftUI

// MARK: - Models (all times are minutes since midnight)

struct SlotSegment: Equatable {
    var start: Int
    var duration: Int
    var end: Int { start + duration }
}

struct SlotPlan: Identifiable, Equatable {
    enum Kind { case whole, split }
    let id = UUID()
    var kind: Kind
    var segments: [SlotSegment]      // 1 segment = fits whole, 2+ = split
    var gap: SlotSegment? = nil      // the free gap a `.whole` plan lives in
}

// MARK: - Small helpers

func toMinutes(_ hours: Double) -> Int { Int((hours * 60).rounded()) }

func clock(_ minutes: Int) -> String {
    String(format: "%02d:%02d", minutes / 60, minutes % 60)
}

func durationLabel(_ minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    switch (h, m) {
    case (0, _): return "\(m) min"
    case (_, 0): return "\(h) hr"
    default:     return "\(h) hr \(m) min"
    }
}

// MARK: - Planner contract

protocol SlotPlanner {
    /// Candidate placements for `task` on `day`. `tasks` is everything currently scheduled.
    /// Return `.whole` plans (one per free slot that fits) or a single `.split` plan, or [].
    func plans(for task: TimelineTask, on day: Date, among tasks: [TimelineTask], now: Date) -> [SlotPlan]
}

// MARK: - Mock planner (UI-only stand-in for the backend)

struct MockSlotPlanner: SlotPlanner {
    var minChunk  = 30      // a split piece is never shorter than this (minutes)
    var maxPieces = 4
    var snap      = kSnapMinutes

    func plans(for task: TimelineTask, on day: Date, among tasks: [TimelineTask], now: Date) -> [SlotPlan] {
        let dur  = toMinutes(task.durationHours)
        let gaps = freeGaps(on: day, excluding: task.id, among: tasks, now: now)

        // 1. Next to the same length slot(s).
        let fitting = gaps.filter { $0.duration >= dur }
        if !fitting.isEmpty {
            return fitting.map {
                SlotPlan(kind: .whole,
                         segments: [SlotSegment(start: $0.start, duration: dur)],
                         gap: $0)
            }
        }

        // 2. Otherwise split, if allowed.
        guard task.isSplittable, !task.isFixed, dur >= 2 * minChunk,
              let split = splitPlan(duration: dur, gaps: gaps) else { return [] }
        return [split]
    }

    // MARK: Free gaps

    /// Free time on `day`, between every other task. On today, nothing before "now".
    func freeGaps(on day: Date, excluding id: UUID, among tasks: [TimelineTask], now: Date) -> [SlotSegment] {
        let cal = Calendar.current
        var lower = kTimelineStartMinutes
        let upper = kTimelineEndMinutes

        if cal.isDate(day, inSameDayAs: now) {
            let c = cal.dateComponents([.hour, .minute], from: now)
            let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            lower = max(lower, ((nowMin + snap - 1) / snap) * snap)
        }
        guard lower < upper else { return [] }

        let busy = tasks
            .filter { $0.id != id && cal.isDate($0.date, inSameDayAs: day) }
            .map { (start: toMinutes($0.startHour), end: toMinutes($0.endHour)) }
            .sorted { $0.start < $1.start }

        var gaps: [SlotSegment] = []
        var cursor = lower
        for b in busy {
            if b.start > cursor {
                let end = min(b.start, upper)
                if end > cursor { gaps.append(SlotSegment(start: cursor, duration: end - cursor)) }
            }
            cursor = max(cursor, b.end)
            if cursor >= upper { break }
        }
        if cursor < upper { gaps.append(SlotSegment(start: cursor, duration: upper - cursor)) }
        return gaps
    }

    // MARK: Split

    /// Uses the real gap sizes (never re-chunks), fewest pieces first, no piece under `minChunk`.
    /// e.g. 90 min with free gaps of 30 and 60 -> 30 + 60 (not 45 + 45).
    private func splitPlan(duration: Int, gaps: [SlotSegment]) -> SlotPlan? {
        var remaining = duration
        var chosen: [SlotSegment] = []

        let bySize = gaps.sorted {
            $0.duration != $1.duration ? $0.duration > $1.duration : $0.start < $1.start
        }
        for gap in bySize {
            guard remaining > 0, chosen.count < maxPieces else { break }
            var take = min(gap.duration, remaining)
            // Don't leave a remainder smaller than the minimum chunk.
            if remaining - take > 0 && remaining - take < minChunk { take = remaining - minChunk }
            guard take >= minChunk else { continue }
            chosen.append(SlotSegment(start: gap.start, duration: take))
            remaining -= take
        }

        guard remaining == 0, chosen.count > 1 else { return nil }
        return SlotPlan(kind: .split, segments: chosen.sorted { $0.start < $1.start })
    }
}

// MARK: - Which plan is the finger on?

/// Picks the plan nearest the tile's proposed position (within `tolerance` minutes).
/// For `.whole` plans the returned segment follows the finger, snapped and clamped inside its gap.
func resolvePlacement(plans: [SlotPlan], proposedStart: Int, duration: Int, tolerance: Int = 30) -> SlotPlan? {
    let propEnd = proposedStart + duration
    var best: (plan: SlotPlan, dist: Int, overlap: Int)? = nil

    for plan in plans {
        var candidate = plan
        var dist = Int.max
        var overlap = 0

        switch plan.kind {
        case .whole:
            guard let gap = plan.gap else { continue }
            dist    = max(0, max(gap.start - propEnd, proposedStart - gap.end))
            overlap = max(0, min(propEnd, gap.end) - max(proposedStart, gap.start))
            let s   = min(max(proposedStart, gap.start), gap.end - duration)
            candidate.segments = [SlotSegment(start: s, duration: duration)]
        case .split:
            for seg in plan.segments {
                dist     = min(dist, max(0, max(seg.start - propEnd, proposedStart - seg.end)))
                overlap += max(0, min(propEnd, seg.end) - max(proposedStart, seg.start))
            }
        }

        guard dist <= tolerance else { continue }
        if let b = best {
            if dist < b.dist || (dist == b.dist && overlap > b.overlap) {
                best = (candidate, dist, overlap)
            }
        } else {
            best = (candidate, dist, overlap)
        }
    }
    return best?.plan
}

// MARK: - Placeholders layer (lives inside the timeline's scroll content)

struct SlotPlaceholdersLayer: View {
    let color: PastelColor
    let plans: [SlotPlan]
    let active: SlotPlan?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(plans.enumerated()), id: \.element.id) { index, plan in
                let isActive = active?.id == plan.id
                PlanView(color: color,
                         plan: isActive ? (active ?? plan) : plan,
                         isActive: isActive)
                    .transition(transition(for: index))
            }
        }
    }

    private func transition(for index: Int) -> AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: AnyTransition.opacity
                .combined(with: .scale(scale: 0.96, anchor: .leading))
                .animation(.spring(response: 0.35, dampingFraction: 0.8).delay(Double(index) * 0.04)),
            removal: .opacity
        )
    }
}

private struct PlanView: View {
    let color: PastelColor
    let plan: SlotPlan
    let isActive: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if plan.kind == .whole, let gap = plan.gap {
                gapShade(gap)
            }
            if plan.kind == .split {
                chain
            }
            ForEach(Array(plan.segments.enumerated()), id: \.offset) { i, seg in
                SlotPlaceholderCard(color: color, segment: seg, isActive: isActive, badge: badge(index: i))
                    .padding(.leading, Theme.labelWidth + 24)
                    .padding(.trailing, 16)
                    .offset(y: topOffsetForHour(Double(seg.start) / 60))
                    .animation(.spring(response: 0.2, dampingFraction: 0.85), value: seg.start)
            }
        }
    }

    /// Soft shading over the whole free gap the task could go in.
    private func gapShade(_ gap: SlotSegment) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(color.fill.opacity(isActive ? 0.30 : 0.16))
            .frame(height: max(CGFloat(gap.duration) * kPPM - 2, 24))
            .padding(.leading, Theme.labelWidth + 24)
            .padding(.trailing, 16)
            .offset(y: topOffsetForHour(Double(gap.start) / 60))
    }

    /// Dotted line in the gutter linking the pieces of a split plan.
    private var chain: some View {
        let x = Theme.labelWidth + 18
        let ys: [CGFloat] = plan.segments.map { seg in
            topOffsetForHour(Double(seg.start) / 60) + max(CGFloat(seg.duration) * kPPM - 2, 24) / 2
        }
        return ZStack(alignment: .topLeading) {
            Path { p in
                guard let first = ys.first, let last = ys.last else { return }
                p.move(to: CGPoint(x: x, y: first))
                p.addLine(to: CGPoint(x: x, y: last))
            }
            .stroke(color.text.opacity(0.5),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [1, 5]))

            ForEach(Array(ys.enumerated()), id: \.offset) { _, y in
                Circle()
                    .fill(color.text.opacity(0.7))
                    .frame(width: 7, height: 7)
                    .offset(x: x - 3.5, y: y - 3.5)
            }
        }
    }

    private func badge(index: Int) -> String? {
        guard plan.kind == .split else { return nil }
        let seg = plan.segments[index]
        return "Part \(index + 1) of \(plan.segments.count) · \(durationLabel(seg.duration))"
    }
}

private struct SlotPlaceholderCard: View {
    let color: PastelColor
    let segment: SlotSegment
    let isActive: Bool
    let badge: String?

    var body: some View {
        let h = max(CGFloat(segment.duration) * kPPM - 2, 24)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        shape
            .fill(color.fill.opacity(isActive ? 0.65 : 0.30))
            .overlay(
                shape.strokeBorder(
                    color.text.opacity(isActive ? 0.95 : 0.55),
                    style: StrokeStyle(lineWidth: isActive ? 2 : 1.5,
                                       dash: isActive ? [] : [6, 4])
                )
            )
            .overlay(alignment: .leading) { label(height: h) }
            .frame(height: h)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isActive)
    }

    @ViewBuilder
    private func label(height h: CGFloat) -> some View {
        let time = Text("\(clock(segment.start)) – \(clock(segment.end))")
            .font(.system(size: 12, weight: isActive ? .bold : .semibold))

        Group {
            if h < 44 {
                HStack(spacing: 6) {
                    time
                    if let badge { Text(badge).font(.system(size: 11)).opacity(0.75) }
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    time
                    if let badge { Text(badge).font(.system(size: 11)).opacity(0.75) }
                }
            }
        }
        .lineLimit(1)
        .foregroundStyle(color.text)
        .padding(.leading, 16)
    }
}

// MARK: - Floating tile (the picked-up copy that follows the finger)

struct FloatingTaskTile: View {
    let task: TimelineTask
    let timeText: String
    let compact: Bool
    let isOverTrash: Bool
    @State private var lifted = false

    var body: some View {
        Group {
            if compact {
                HStack(spacing: 6) {
                    Text(task.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(timeText).font(.system(size: 12)).opacity(0.7).lineLimit(1)
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title).font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(timeText).font(.system(size: 12)).opacity(0.7).lineLimit(1)
                }
            }
        }
        .foregroundStyle(task.color.text)
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, compact ? 0 : 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: compact ? .leading : .topLeading)
        .background(task.color.fill)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(task.color.text)
                .frame(width: 6.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(lifted ? 0.22 : 0),
                radius: lifted ? 16 : 0, y: lifted ? 10 : 0)
        .scaleEffect(isOverTrash ? 0.78 : (lifted ? 1.05 : 1))
        .opacity(isOverTrash ? 0.85 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isOverTrash)
        .onAppear {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) { lifted = true }
        }
    }
}
