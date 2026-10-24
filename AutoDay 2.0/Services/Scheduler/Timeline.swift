// Timeline.swift — AutoDay · Scheduler
// Step 0: free slots for the 7-day horizon, buffers, daily cap.

import Foundation

struct TimeRange: Hashable {
    var start: Date
    var end: Date
    var length: TimeInterval { end.timeIntervalSince(start) }
    var minutes: Int { Int((length / 60).rounded()) }
    func overlaps(_ o: TimeRange) -> Bool { start < o.end && o.start < end }
}

struct DayFrame {
    let index: Int
    let dayStart: Date       // start of calendar day
    let open: Date           // max(wake, now) on day 0, wake otherwise
    let close: Date          // sleep time
    var cap: Int = 0         // minutes of flexible work allowed (80% of free time)
    var used: Int = 0        // minutes of flexible work placed (incl. buffers)
}

/// A busy interval. `range` already includes the trailing 10-minute buffer.
struct TimelineBlock {
    var range: TimeRange
    var taskId: UUID?        // nil = hard block (fixed / frozen / pinned / history)
    var chunk: Int
    var usedMinutes: Int     // counted toward the daily cap (0 for hard blocks)
    var dayIndex: Int
}

struct Timeline {

    let calendar: Calendar
    let now: Date
    private(set) var days: [DayFrame]
    private(set) var blocks: [TimelineBlock] = []
    private let buffer: TimeInterval = TimeInterval(SchedulerConstants.bufferMinutes * 60)

    // MARK: - Init

    init(preferences: UserPreferences, now: Date, calendar: Calendar) {
        self.calendar = calendar
        self.now = now
        let sod = calendar.startOfDay(for: now)
        var frames: [DayFrame] = []
        for i in 0..<SchedulerConstants.horizonDays {
            let d     = calendar.date(byAdding: .day, value: i, to: sod)!
            let wake  = calendar.date(byAdding: .minute, value: preferences.dayStartMinutes, to: d)!
            let sleep = calendar.date(byAdding: .minute, value: preferences.dayEndMinutes, to: d)!
            var open = wake
            if i == 0 { open = max(wake, Timeline.ceilToGrid(now)) }
            if open > sleep { open = sleep }
            frames.append(DayFrame(index: i, dayStart: d, open: open, close: sleep))
        }
        self.days = frames
    }

    // MARK: - Helpers

    static func ceilToGrid(_ d: Date) -> Date {
        let g = SchedulerConstants.gridSeconds
        let t = d.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (t / g).rounded(.up) * g)
    }

    /// Index (0…6) of the calendar day containing `date`, or nil if outside the horizon.
    func dayIndex(of date: Date) -> Int? {
        let a = calendar.startOfDay(for: now)
        let b = calendar.startOfDay(for: date)
        guard let n = calendar.dateComponents([.day], from: a, to: b).day else { return nil }
        return days.indices.contains(n) ? n : nil
    }

    private mutating func insert(_ b: TimelineBlock) {
        blocks.append(b)
        blocks.sort { $0.range.start < $1.range.start }
    }

    // MARK: - Blocks

    /// Fixed / frozen / pinned / recent-history time. Adds the trailing buffer.
    mutating func addHardBlock(_ r: TimeRange) {
        let padded = TimeRange(start: r.start, end: r.end.addingTimeInterval(buffer))
        insert(TimelineBlock(range: padded, taskId: nil, chunk: 0, usedMinutes: 0,
                             dayIndex: dayIndex(of: r.start) ?? -1))
    }

    /// Call once after every hard block is in: cap = 80% of each day's remaining free time.
    mutating func finalizeCaps() {
        for i in days.indices {
            let free = gaps(onDay: i).reduce(0) { $0 + $1.minutes }
            days[i].cap  = Int(Double(free) * SchedulerConstants.dailyCapRatio)
            days[i].used = 0
        }
    }

    mutating func place(taskId: UUID, chunk: Int, range: TimeRange) {
        let idx  = dayIndex(of: range.start) ?? 0
        let used = range.minutes + SchedulerConstants.bufferMinutes
        let padded = TimeRange(start: range.start, end: range.end.addingTimeInterval(buffer))
        insert(TimelineBlock(range: padded, taskId: taskId, chunk: chunk, usedMinutes: used, dayIndex: idx))
        days[idx].used += used
    }

    mutating func release(taskId: UUID) -> [TimelineBlock] {
        let removed = blocks.filter { $0.taskId == taskId }
        blocks.removeAll { $0.taskId == taskId }
        for b in removed where days.indices.contains(b.dayIndex) {
            days[b.dayIndex].used -= b.usedMinutes
        }
        return removed
    }

    mutating func restore(_ restored: [TimelineBlock]) {
        for b in restored {
            insert(b)
            if days.indices.contains(b.dayIndex) { days[b.dayIndex].used += b.usedMinutes }
        }
    }

    /// True if [range + buffer] would touch any existing block.
    func conflictsWithBlocks(_ range: TimeRange) -> Bool {
        let probe = TimeRange(start: range.start, end: range.end.addingTimeInterval(buffer))
        return blocks.contains { $0.range.overlaps(probe) }
    }

    // MARK: - Gaps

    /// Free gaps for a day. The last gap may extend `buffer` past sleep so a
    /// task can end exactly at sleep time.
    func gaps(onDay i: Int) -> [TimeRange] {
        guard days.indices.contains(i) else { return [] }
        let f = days[i]
        guard f.open < f.close else { return [] }
        let regionStart = f.open
        let regionEnd   = f.close.addingTimeInterval(buffer)
        var cursor = regionStart
        var out: [TimeRange] = []
        for b in blocks where b.range.end > regionStart && b.range.start < regionEnd {
            if b.range.start > cursor { out.append(TimeRange(start: cursor, end: b.range.start)) }
            cursor = max(cursor, b.range.end)
        }
        if cursor < regionEnd { out.append(TimeRange(start: cursor, end: regionEnd)) }
        return out
    }

    /// Free minutes between `from` and `until` (Step 2 feasibility gate).
    func freeMinutes(from: Date, until: Date?) -> Int {
        var total = 0
        for i in days.indices {
            let close = days[i].close
            for g in gaps(onDay: i) {
                let s = max(g.start, from)
                var e = min(g.end, close)
                if let u = until { e = min(e, u) }
                if e > s { total += Int(e.timeIntervalSince(s) / 60) }
            }
        }
        return total
    }

    func largestGapMinutes(from: Date, until: Date?) -> Int {
        var best = 0
        for i in days.indices {
            for g in gaps(onDay: i) {
                let s = max(g.start, from)
                var e = g.end.addingTimeInterval(-buffer)
                if let u = until { e = min(e, u) }
                best = max(best, Int(e.timeIntervalSince(s) / 60))
            }
        }
        return max(best, 0)
    }

    // MARK: - Slot search

    /// Tightest-fit gap that can hold `minutes` (+ trailing buffer) on day `i`.
    func findSlot(minutes: Int,
                  onDay i: Int,
                  notBefore: Date,
                  deadline: Date?,
                  window: (start: Int, end: Int)?,
                  respectCap: Bool) -> TimeRange? {
        guard days.indices.contains(i), minutes > 0 else { return nil }
        let f = days[i]
        if respectCap && f.used + minutes + SchedulerConstants.bufferMinutes > f.cap { return nil }

        let dur = TimeInterval(minutes * 60)
        var best: (range: TimeRange, gapLength: TimeInterval)?

        for g in gaps(onDay: i) {
            var earliest  = Timeline.ceilToGrid(max(g.start, notBefore))
            var latestEnd = g.end.addingTimeInterval(-buffer)
            if let w = window {
                let ws = calendar.date(byAdding: .minute, value: w.start, to: f.dayStart)!
                let we = calendar.date(byAdding: .minute, value: w.end, to: f.dayStart)!
                earliest  = Timeline.ceilToGrid(max(earliest, ws))
                latestEnd = min(latestEnd, we)
            }
            if let dl = deadline { latestEnd = min(latestEnd, dl) }
            guard earliest.addingTimeInterval(dur) <= latestEnd else { continue }

            let r = TimeRange(start: earliest, end: earliest.addingTimeInterval(dur))
            if best == nil || g.length < best!.gapLength { best = (r, g.length) }
        }
        return best?.range
    }

    /// Step 4, attempt 3: fill the largest gaps with chunks ≥ 30 min.
    /// Returns as many chunks as fit (≤ `remaining` minutes in total).
    func splitChunks(remaining: Int,
                     onDay i: Int,
                     notBefore: Date,
                     deadline: Date?,
                     respectCap: Bool) -> [TimeRange] {
        guard days.indices.contains(i) else { return [] }
        let minChunk = SchedulerConstants.minChunkMinutes
        let bufMin   = SchedulerConstants.bufferMinutes

        var usable: [(start: Date, maxMinutes: Int)] = []
        for g in gaps(onDay: i) {
            let s = Timeline.ceilToGrid(max(g.start, notBefore))
            var endLimit = g.end.addingTimeInterval(-buffer)
            if let dl = deadline { endLimit = min(endLimit, dl) }
            let m = Int(endLimit.timeIntervalSince(s) / 60)
            if m >= minChunk { usable.append((s, m)) }
        }
        usable.sort { $0.maxMinutes > $1.maxMinutes }      // largest gaps first

        var rem = remaining
        var capLeft = respectCap ? days[i].cap - days[i].used : Int.max / 2
        var out: [TimeRange] = []

        for u in usable {
            if rem <= 0 { break }
            var c = min(rem, u.maxMinutes, capLeft - bufMin)
            if c < rem { c = (c / 5) * 5 }
            if c < minChunk { continue }
            if rem - c > 0 && rem - c < minChunk {          // never leave a piece < 30
                c = rem - minChunk
                if c < minChunk { continue }
            }
            out.append(TimeRange(start: u.start, end: u.start.addingTimeInterval(TimeInterval(c * 60))))
            rem     -= c
            capLeft -= (c + bufMin)
        }
        return out.sorted { $0.start < $1.start }
    }
}
