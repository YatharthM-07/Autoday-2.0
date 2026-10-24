// EngineSlotPlanner.swift — AutoDay · Services
// Replaces MockSlotPlanner. Candidate drop slots that follow the scheduler's real rules:
// 07:00–23:00 day bounds, 10-minute buffer around every tile, nothing before "now",
// no slots on past days, fixed and pinned tiles are walls, 30-minute minimum split piece.
// Other (soft) tiles are still treated as busy so the drag feels the same as before.

import Foundation

struct EngineSlotPlanner: SlotPlanner {
    var minChunk  = SchedulerConstants.minChunkMinutes
    var buffer    = SchedulerConstants.bufferMinutes
    var maxPieces = 4
    var snap      = kSnapMinutes

    func plans(for task: TimelineTask, on day: Date, among tasks: [TimelineTask], now: Date) -> [SlotPlan] {
        let dur  = toMinutes(task.durationHours)
        guard dur > 0 else { return [] }
        let gaps = freeGaps(on: day, excluding: task.id, among: tasks, now: now)

        let fitting = gaps.filter { $0.duration >= dur }
        if !fitting.isEmpty {
            return fitting.map {
                SlotPlan(kind: .whole, segments: [SlotSegment(start: $0.start, duration: dur)], gap: $0)
            }
        }

        // Only an un-split, splittable, flexible task can be split by dropping it.
        guard task.isSplittable, !task.isFixed, !task.isChunk, dur >= 2 * minChunk,
              let split = splitPlan(duration: dur, gaps: gaps) else { return [] }
        return [split]
    }

    func freeGaps(on day: Date, excluding id: UUID, among tasks: [TimelineTask], now: Date) -> [SlotSegment] {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: day)
        let today    = cal.startOfDay(for: now)
        if dayStart < today { return [] }                                   // past days: no slots

        var lower = kTimelineStartMinutes
        let upper = kTimelineEndMinutes
        if dayStart == today {
            let c = cal.dateComponents([.hour, .minute], from: now)
            let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
            lower = max(lower, ((nowMin + snap - 1) / snap) * snap)
        }
        guard lower < upper else { return [] }

        let busy = tasks
            .filter { t in
                guard t.id != id, cal.isDate(t.date, inSameDayAs: day) else { return false }
                if t.isMissedRow { return false }
                if t.isDone && dayStart == today {
                    // Done frees its unused future time (the engine blocks only up to now).
                    let c = cal.dateComponents([.hour, .minute], from: now)
                    let nowH = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
                    if t.startHour >= nowH { return false }
                }
                return true
            }
            .map { (start: toMinutes($0.startHour) - buffer, end: toMinutes($0.endHour) + buffer) }
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

        // Snap each gap start up to the drag grid so placeholders sit on the grid.
        return gaps.compactMap { g in
            let s = ((g.start + snap - 1) / snap) * snap
            let d = g.end - s
            return d > 0 ? SlotSegment(start: s, duration: d) : nil
        }
    }

    /// Real gap sizes (never re-chunks), fewest pieces first, no piece under `minChunk`.
    private func splitPlan(duration: Int, gaps: [SlotSegment]) -> SlotPlan? {
        var remaining = duration
        var chosen: [SlotSegment] = []
        let bySize = gaps.sorted { $0.duration != $1.duration ? $0.duration > $1.duration : $0.start < $1.start }
        for gap in bySize {
            guard remaining > 0, chosen.count < maxPieces else { break }
            var take = min(gap.duration, remaining)
            if remaining - take > 0 && remaining - take < minChunk { take = remaining - minChunk }
            guard take >= minChunk else { continue }
            chosen.append(SlotSegment(start: gap.start, duration: take))
            remaining -= take
        }
        guard remaining == 0, chosen.count > 1 else { return nil }
        return SlotPlan(kind: .split, segments: chosen.sorted { $0.start < $1.start })
    }
}
