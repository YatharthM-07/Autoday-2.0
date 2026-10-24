// SchedulerEngine.swift — AutoDay · Scheduler
// Pure function: (tasks, previous schedule, prefs, now) → new schedule.
// No store access, no UI, no side effects. Implements Steps 0–5 of the spec.

import Foundation

enum SchedulerEngine {
    static func run(_ input: SchedulerInput) -> SchedulerOutput {
        EngineRun(input).execute()
    }
}

// MARK: - One engine pass

private struct Placement {
    var ranges: [TimeRange]
    var windowPenalty: Bool
}

private struct Undo {
    var taskId: UUID
    var blocks: [TimelineBlock]
    var ranges: [TimeRange]
    var penalty: Bool
}

private final class EngineRun {

    let input: SchedulerInput
    let cal: Calendar
    let now: Date
    var timeline: Timeline

    // Rows that pass straight through to the output
    var historyRows: [TaskSchedule] = []   // finished / past rows
    var fixedRows:   [TaskSchedule] = []   // Step 1: fixed tasks = blocked slots
    var pinnedRows:  [TaskSchedule] = []   // user-dragged flexible tasks
    var frozenRows:  [TaskSchedule] = []   // in progress / starting within 15 min

    // Previous soft placements, for the stability rule
    var softPrev: [UUID: [TaskSchedule]] = [:]

    // This run's placements
    var placed: [UUID: [TimeRange]] = [:]
    var placedPenalty: [UUID: Bool] = [:]
    var scoredById: [UUID: ScoredTask] = [:]

    var statusUpdates: [UUID: TaskStatus] = [:]
    var blocked: [BlockedTask] = []
    var fixedConflicts: [FixedConflict] = []

    init(_ input: SchedulerInput) {
        self.input = input
        self.cal = input.calendar
        self.now = input.now
        self.timeline = Timeline(preferences: input.preferences, now: input.now, calendar: input.calendar)
    }

    // MARK: - Driver

    func execute() -> SchedulerOutput {
        let buffer = SchedulerConstants.bufferMinutes
        let tasksById = Dictionary(input.tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let live   = input.tasks.filter { !$0.isTemplate }
        let active = live.filter { $0.status != .done && $0.status != .missed }
        let isFixedActive: (AppTask) -> Bool = { $0.isFixed && $0.fixedStart != nil }
        let fixedTasks = active.filter(isFixedActive)
        let flexible   = active.filter { !isFixedActive($0) && !$0.isUnscheduled }
        let pinnedIds  = Set(flexible.filter { $0.isManuallyPlaced }.map { $0.id })
        let activeIds  = Set(active.map { $0.id })

        // ── Partition previous rows ─────────────────────────────────────
        for row in input.previousSchedule {
            guard let t = tasksById[row.taskId] else { continue }          // task deleted
            if row.isMissed { historyRows.append(row); continue }
            if activeIds.contains(t.id) && isFixedActive(t) { continue }   // regenerated below (Step 1)
            if !activeIds.contains(t.id) || row.end <= now { historyRows.append(row); continue }
            if t.isUnscheduled && !t.isFixed { continue }                  // pulled back to the Unscheduled list
            if pinnedIds.contains(t.id) { pinnedRows.append(row); continue }
            softPrev[t.id, default: []].append(row)
        }

        // ── Step 1: fixed tasks become blocked slots ────────────────────
        for t in fixedTasks {
            let start = t.fixedStart!
            let end   = start.addingTimeInterval(TimeInterval(t.duration * 60))
            let row = TaskSchedule(taskId: t.id, start: start, end: end)
            if end <= now { historyRows.append(row); continue }
            fixedRows.append(row)                                          // even outside the 7-day horizon
        }

        // Two fixed tasks overlapping: flag once, keep both.
        for i in fixedRows.indices {
            for j in (i + 1)..<max(fixedRows.count, i + 1) {
                let a = fixedRows[i], b = fixedRows[j]
                if a.start < b.end && b.start < a.end,
                   let ta = tasksById[a.taskId], let tb = tasksById[b.taskId] {
                    fixedConflicts.append(FixedConflict(firstId: ta.id, secondId: tb.id,
                                                        firstTitle: ta.title, secondTitle: tb.title))
                }
            }
        }

        // ── Step 0: hard blocks (history buffer, fixed, frozen, pinned) ─
        for row in historyRows {
            let isDone = tasksById[row.taskId]?.status == .done
            let blockEnd = isDone ? min(row.end, now) : row.end          // Done: the unused future slot is free again
            guard blockEnd > row.start, blockEnd.addingTimeInterval(TimeInterval(buffer * 60)) > now else { continue }
            timeline.addHardBlock(TimeRange(start: row.start, end: blockEnd))
        }
        let fixedRanges = fixedRows.map { TimeRange(start: $0.start, end: $0.end) }
        for r in fixedRanges { timeline.addHardBlock(r) }

        // Frozen zone: in-progress or starting within 15 min. Never moved —
        // unless snoozed (user said "later") or a fixed task needs the space.
        let leadEnd = now.addingTimeInterval(TimeInterval(SchedulerConstants.frozenLeadMinutes * 60))
        for (id, rows) in softPrev {
            guard let t = tasksById[id] else { continue }
            if let s = t.snoozedUntil, s > now { continue }
            var keep: [TaskSchedule] = []
            for row in rows {
                let r = TimeRange(start: row.start, end: row.end)
                if row.start <= leadEnd && !fixedRanges.contains(where: { $0.overlaps(r) }) {
                    frozenRows.append(row)
                } else {
                    keep.append(row)
                }
            }
            softPrev[id] = keep
        }
        for row in frozenRows + pinnedRows {
            timeline.addHardBlock(TimeRange(start: row.start, end: row.end))
        }
        timeline.finalizeCaps()                                   // 80% daily cap

        // ── Steps 2 & 3: feasibility gate + scoring ─────────────────────
        let workedRows = (historyRows + frozenRows).filter { !$0.isMissed }   // missed attempts don't count as work
        var scored: [ScoredTask] = []
        for t in flexible where !pinnedIds.contains(t.id) {
            let worked = workedRows.filter { $0.taskId == t.id }.reduce(0) { $0 + $1.minutes }
            let rem = t.duration - worked
            if rem <= 0 { statusUpdates[t.id] = restingStatus(t); continue }

            let e = earliest(for: t)
            let slack: Double? = t.deadline.map { $0.timeIntervalSince(e) / 3600 - Double(rem) / 60 }
            var s = ScoredTask(task: t, remaining: rem, earliest: e, slackHours: slack,
                               score: TaskScorer.score(task: t, slackHours: slack))

            if let dl = t.deadline {
                let avail = timeline.freeMinutes(from: e, until: dl)
                s.availableMinutes = avail
                if avail < rem {                                   // deadline violation → BLOCK
                    block(s, .deadlineTooTight(available: avail, needed: rem))
                    continue
                }
            }
            scored.append(s)
        }
        scored.sort(by: TaskScorer.outranks)

        // ── Step 4: place each task, in sorted order ────────────────────
        for s in scored {
            scoredById[s.task.id] = s

            // "Done" frees a slot: non-spread tasks may be pulled forward.
            if input.pullForward, !isSpread(s),
               let prevMin = softPrev[s.task.id]?.map({ $0.start }).min(),
               let fresh = attempt(s, respectCap: true),
               let first = fresh.ranges.first, first.start < prevMin {
                commit(s, fresh)
                continue
            }

            if tryStay(s) { continue }                             // stability rule

            if let p = attempt(s, respectCap: true) { commit(s, p); continue }   // 1–4

            if s.task.priority == .urgent || s.slackExhausted {    // 5
                if let p = attempt(s, respectCap: false) { commit(s, p); continue }
                if displace(for: s) { continue }
            }
            blockAfterFailure(s)                                   // 6
        }

        // ── Step 5: spread overload ─────────────────────────────────────
        rebalance()

        return assemble()
    }

    // MARK: - Status / earliest

    func restingStatus(_ t: AppTask) -> TaskStatus {
        if let s = t.snoozedUntil, s > now { return .snoozed }
        return .pending
    }

    func earliest(for t: AppTask) -> Date {
        var e = now
        if let s = t.snoozedUntil, s > e { e = s }
        if let d = t.instanceDate {
            let open = cal.date(byAdding: .minute,
                                value: input.preferences.dayStartMinutes,
                                to: cal.startOfDay(for: d))!
            if open > e { e = open }
        }
        return e
    }

    func isSpread(_ s: ScoredTask) -> Bool {
        s.task.deadline != nil && (s.slackHours ?? 0) > SchedulerConstants.spreadSlackHours
    }

    func validWindow(_ t: AppTask) -> (start: Int, end: Int)? {
        if let a = t.windowStart, let b = t.windowEnd, a < b { return (a, b) }
        return nil
    }

    // MARK: - Stability rule

    /// Keep the previous slot(s) if they are still valid. Returns true if kept.
    func tryStay(_ s: ScoredTask) -> Bool {
        guard let prev = softPrev[s.task.id], !prev.isEmpty else { return false }
        let rows = prev.sorted { $0.start < $1.start }
        guard rows.reduce(0, { $0 + $1.minutes }) == s.remaining else { return false }

        let exempt = s.task.priority == .urgent || s.slackExhausted   // may exceed the cap
        let buf = SchedulerConstants.bufferMinutes
        var extra: [Int: Int] = [:]

        for r in rows {
            guard r.start >= s.earliest else { return false }
            if let dl = s.task.deadline, r.end > dl { return false }
            guard let i = timeline.dayIndex(of: r.start) else { return false }
            let f = timeline.days[i]
            guard r.start >= f.open, r.end <= f.close else { return false }
            if timeline.conflictsWithBlocks(TimeRange(start: r.start, end: r.end)) { return false }
            extra[i, default: 0] += r.minutes + buf
            if !exempt && f.used + (extra[i] ?? 0) > f.cap { return false }
        }

        commit(s, Placement(ranges: rows.map { TimeRange(start: $0.start, end: $0.end) },
                            windowPenalty: rows.contains { $0.windowPenalty }))
        return true
    }

    // MARK: - Placement attempts 1–4

    func dayOrder(for s: ScoredTask, restrictedTo restrict: ClosedRange<Int>?) -> [Int] {
        guard var first = timeline.dayIndex(of: s.earliest) else { return [] }
        var last = timeline.days.count - 1
        if let dl = s.task.deadline {
            if dl <= s.earliest { return [] }
            if let di = timeline.dayIndex(of: dl) { last = min(last, di) }
        }
        if let r = restrict {
            first = max(first, r.lowerBound)
            last  = min(last, r.upperBound)
        }
        guard first <= last else { return [] }

        // Step 5: slack > 24h → latest feasible day minus 1, not the earliest slot.
        if isSpread(s), let dl = s.task.deadline {
            var latest = first
            for i in stride(from: last, through: first, by: -1) {
                let start = max(timeline.days[i].open, s.earliest)
                if start.addingTimeInterval(TimeInterval(s.remaining * 60)) <= dl { latest = i; break }
            }
            let target = max(latest - 1, first)
            var order = [target]
            if target + 1 <= last { order += Array((target + 1)...last) }          // next day with capacity
            if target - 1 >= first { order += Array(stride(from: target - 1, through: first, by: -1)) }
            return order
        }
        return Array(first...last)
    }

    /// Attempts 1–4. Pure search: does not modify the timeline.
    func attempt(_ s: ScoredTask, respectCap: Bool, days restrict: ClosedRange<Int>? = nil) -> Placement? {
        let t = s.task
        let order = dayOrder(for: s, restrictedTo: restrict)
        let window = validWindow(t)
        let hasWindow = window != nil

        for i in order {                                           // attempt 4 = next day
            if let w = window,                                     // 1. preferred window
               let r = timeline.findSlot(minutes: s.remaining, onDay: i, notBefore: s.earliest,
                                         deadline: t.deadline, window: w, respectCap: respectCap) {
                return Placement(ranges: [r], windowPenalty: false)
            }
            if let r = timeline.findSlot(minutes: s.remaining, onDay: i, notBefore: s.earliest,   // 2. any gap
                                         deadline: t.deadline, window: nil, respectCap: respectCap) {
                return Placement(ranges: [r], windowPenalty: hasWindow)
            }
            if t.splittable {                                      // 3. split within the day
                let chunks = timeline.splitChunks(remaining: s.remaining, onDay: i, notBefore: s.earliest,
                                                  deadline: t.deadline, respectCap: respectCap)
                if chunks.reduce(0, { $0 + $1.minutes }) == s.remaining {
                    return Placement(ranges: chunks, windowPenalty: hasWindow)
                }
            }
        }

        if t.splittable {                                          // 3b. split across days
            var rem = s.remaining
            var all: [TimeRange] = []
            for i in order {
                if rem <= 0 { break }
                let chunks = timeline.splitChunks(remaining: rem, onDay: i, notBefore: s.earliest,
                                                  deadline: t.deadline, respectCap: respectCap)
                all += chunks
                rem -= chunks.reduce(0) { $0 + $1.minutes }
            }
            if rem == 0 && !all.isEmpty { return Placement(ranges: all, windowPenalty: hasWindow) }
        }
        return nil
    }

    func commit(_ s: ScoredTask, _ p: Placement) {
        let sorted = p.ranges.sorted { $0.start < $1.start }
        for (i, r) in sorted.enumerated() {
            timeline.place(taskId: s.task.id, chunk: i, range: r)
        }
        placed[s.task.id] = sorted
        placedPenalty[s.task.id] = p.windowPenalty
        statusUpdates[s.task.id] = restingStatus(s.task)
        blocked.removeAll { $0.taskId == s.task.id }
    }

    // MARK: - Attempt 5: displace

    func unplace(_ id: UUID) -> Undo {
        let b = timeline.release(taskId: id)
        let r = placed.removeValue(forKey: id) ?? []
        let p = placedPenalty.removeValue(forKey: id) ?? false
        return Undo(taskId: id, blocks: b, ranges: r, penalty: p)
    }

    func restore(_ u: Undo) {
        timeline.restore(u.blocks)
        placed[u.taskId] = u.ranges
        placedPenalty[u.taskId] = u.penalty
    }

    /// Bump the lowest-score placed task, place `s`, then re-place the bumped task from attempt 1.
    func displace(for s: ScoredTask) -> Bool {
        let candidates = placed.keys
            .compactMap { scoredById[$0] }
            .filter { TaskScorer.outranks(s, $0) }
            .sorted { TaskScorer.outranks($1, $0) }              // lowest rank first

        for c in candidates {
            let undo = unplace(c.task.id)
            if let p = attempt(s, respectCap: false) {
                commit(s, p)
                if let q = attempt(c, respectCap: true) { commit(c, q) } else { blockAfterFailure(c) }
                return true
            }
            restore(undo)
        }
        return false
    }

    // MARK: - Step 5b: rebalance over-cap days

    func rebalance() {
        for i in timeline.days.indices {
            var guardCount = 0
            while timeline.days[i].used > timeline.days[i].cap && guardCount < 50 {
                guardCount += 1
                var movable: [ScoredTask] = []
                for entry in placed {
                    guard let s = scoredById[entry.key] else { continue }
                    let onDay = entry.value.contains { timeline.dayIndex(of: $0.start) == i }
                    if !onDay { continue }
                    if s.task.deadline != nil && !isSpread(s) { continue }     // only slack > 24h may move
                    movable.append(s)
                }
                movable.sort { TaskScorer.outranks($1, $0) }                  // lowest score first

                var moved = false
                for c in movable {
                    let undo = unplace(c.task.id)
                    if i + 1 < timeline.days.count,
                       let p = attempt(c, respectCap: true, days: (i + 1)...(timeline.days.count - 1)) {
                        commit(c, p)
                        moved = true
                        break
                    }
                    restore(undo)
                }
                if !moved { break }
            }
        }
    }

    // MARK: - Step 6 / blocking

    func blockAfterFailure(_ s: ScoredTask) {
        if s.task.deadline != nil {
            let avail = timeline.freeMinutes(from: s.earliest, until: s.task.deadline)
            block(s, .deadlineTooTight(available: avail, needed: s.remaining))
        } else {
            block(s, .noRoomInHorizon(needed: s.remaining))
        }
    }

    func block(_ s: ScoredTask, _ reason: BlockReason) {
        let t = s.task
        let capacity: Int
        if t.deadline != nil {
            let total = timeline.freeMinutes(from: s.earliest, until: t.deadline)
            let gap   = timeline.largestGapMinutes(from: s.earliest, until: t.deadline)
            capacity = t.splittable ? total : min(total, gap)
        } else {
            capacity = timeline.largestGapMinutes(from: s.earliest, until: nil)
        }
        let newRemaining = min(max(15, (capacity / 5) * 5), max(15, s.remaining - 15))
        let suggested = max(15, t.duration - (s.remaining - newRemaining))

        blocked.removeAll { $0.taskId == t.id }
        blocked.append(BlockedTask(taskId: t.id, title: t.title, reason: reason, suggestedDuration: suggested))
        statusUpdates[t.id] = .blocked
    }

    // MARK: - Output

    func assemble() -> SchedulerOutput {
        var rows = historyRows + fixedRows + pinnedRows + frozenRows
        for entry in placed {
            let penalty = placedPenalty[entry.key] ?? false
            for r in entry.value {
                rows.append(TaskSchedule(taskId: entry.key, start: r.start, end: r.end,
                                         chunkIndex: 0, windowPenalty: penalty))
            }
        }

        var out: [TaskSchedule] = []
        for (_, list) in Dictionary(grouping: rows, by: { $0.taskId }) {
            let ordered = list.sorted { $0.start < $1.start }
            for (i, row) in ordered.enumerated() {
                var r = row
                r.chunkIndex = i
                out.append(r)
            }
        }
        out.sort { $0.start < $1.start }

        // Alert 10: days where planned flexible work is above the daily cap
        // (only possible for Urgent / no-slack tasks, which may exceed it).
        let overloaded = timeline.days
            .filter { $0.used > $0.cap }
            .map { OverloadedDay(date: $0.dayStart, plannedMinutes: $0.used, capMinutes: $0.cap) }

        return SchedulerOutput(schedule: out,
                               statusUpdates: statusUpdates,
                               blocked: blocked,
                               fixedConflicts: fixedConflicts,
                               overloadedDays: overloaded)
    }
}
