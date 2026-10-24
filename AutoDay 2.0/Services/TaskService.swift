// TaskService.swift — AutoDay · Services
// User actions (add / edit / delete / done / snooze / drag / place) → mutate store → re-run scheduler.

import Foundation

final class TaskService {

    static let shared = TaskService()
    private init() {}

    private var store: TaskStore { TaskStore.shared }
    private func rerun(_ trigger: SchedulerOrchestrator.Trigger, now: Date = Date()) {
        SchedulerOrchestrator.shared.run(trigger: trigger, now: now)
    }

    // MARK: - Validation

    enum ValidationError: LocalizedError {
        case titleEmpty, badWindow
        var errorDescription: String? {
            switch self {
            case .titleEmpty: return "Title cannot be empty."
            case .badWindow:  return "Preferred window must end after it starts."
            }
        }
    }

    func validate(_ t: AppTask) -> ValidationError? {
        if t.title.trimmingCharacters(in: .whitespaces).isEmpty { return .titleEmpty }
        if let a = t.windowStart, let b = t.windowEnd, a >= b { return .badWindow }
        return nil
    }

    // MARK: - Create / edit / delete

    /// Fixed-vs-fixed overlap is NOT rejected: the engine flags it once and keeps both.
    @discardableResult
    func add(_ task: AppTask) -> AppTask {
        store.add(task)
        rerun(.added)
        return task
    }

    /// Edit. Editing a repeating occurrence edits the whole series (its template).
    func update(_ task: AppTask) {
        var t = task
        if let rootId = t.templateId, var tpl = store.task(id: rootId) {
            // Occurrence -> template: copy the edited fields up, keep identity.
            tpl.title = t.title; tpl.duration = t.duration; tpl.priority = t.priority
            tpl.splittableOverride = t.splittableOverride
            if let r = t.repeatRule { tpl.repeatRule = r }
            tpl.isFixed = t.isFixed
            if t.isFixed, let f = t.fixedStart {
                // Only the time of day carries to the series; its anchor date (weekly/monthly) stays.
                let cal = Calendar.current
                let c = cal.dateComponents([.hour, .minute], from: f)
                let base = tpl.fixedStart ?? tpl.dateCreated
                tpl.fixedStart = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: base)
            }
            t = tpl
        }
        if let old = store.task(id: t.id) {
            // Changing length or kind invalidates any placement.
            if old.duration != t.duration || old.isFixed != t.isFixed {
                store.removeRows(for: t.id)
                t.isManuallyPlaced = false
            }
            if t.isTemplate { removeFutureInstances(of: t.id); store.removeRows(for: t.id) }
            // An edited task that was blocked/missed gets a fresh chance.
            if t.status == .blocked { t.status = .pending }
        }
        store.replaceTask(t)
        rerun(.edited)
    }

    /// Deletes the task (a whole series for a repeat). Returns a snapshot for Undo.
    @discardableResult
    func delete(id: UUID) -> TaskSnapshot? {
        guard let t = store.task(id: id) else { return nil }
        var ids = [id]
        if t.isTemplate || t.templateId != nil {
            let root = t.templateId ?? t.id
            ids = store.tasks.filter {
                ($0.id == root || $0.templateId == root) &&
                ($0.id == root || $0.status == .pending || $0.status == .blocked || $0.status == .snoozed || $0.id == id)
            }.map(\.id)
        }
        let snap = store.snapshot(of: ids)
        ids.forEach { store.remove(id: $0) }
        rerun(.edited)
        return snap
    }

    func restore(_ snap: TaskSnapshot) {
        store.restore(snap)
        rerun(.edited)
    }

    private func removeFutureInstances(of templateId: UUID) {
        store.tasks
            .filter { $0.templateId == templateId && ($0.status == .pending || $0.status == .blocked || $0.status == .snoozed) }
            .forEach { store.remove(id: $0.id) }
    }

    // MARK: - Done / Undo done

    /// Done: the row keeps its size; the engine frees the unused future time.
    func markDone(id: UUID, now: Date = Date()) {
        guard var t = store.task(id: id) else { return }
        t.status = .done
        t.snoozedUntil = nil
        store.replaceTask(t)
        store.append(event: TaskEvent(taskId: id, kind: .completed, date: now, minutes: t.duration))
        rerun(.done, now: now)
    }

    /// Undo done: back to pending; the original slot is still there, so it comes back exactly.
    func markPending(id: UUID, now: Date = Date()) {
        guard var t = store.task(id: id), t.status == .done else { return }
        t.status = .pending
        store.replaceTask(t)
        rerun(.edited, now: now)
    }

    // MARK: - Snooze

    /// Snooze until an exact time. Returns a snapshot so the UI can Undo it exactly.
    @discardableResult
    func snooze(id: UUID, until: Date, now: Date = Date()) -> TaskSnapshot? {
        guard var t = store.task(id: id) else { return nil }
        let snap = store.snapshot(of: [id])
        t.rescheduleCount += 1
        t.isManuallyPlaced = false
        store.append(event: TaskEvent(taskId: id, kind: .snoozed, date: now, minutes: 0))

        if t.isFixed {
            // Fixed: shifting the start is the snooze (the engine never moves a fixed task itself).
            t.fixedStart = until
            store.removeRows(for: id)
        } else {
            t.snoozedUntil = until
            t.status = .snoozed
            // A repeat occurrence snoozed past its own day moves with it.
            if t.instanceDate != nil, let dl = t.deadline, until >= dl {
                t.deadline = store.preferences.dayEnd(for: until)
            }
        }
        store.replaceTask(t)
        rerun(.snoozed, now: now)
        return snap
    }

    /// Notification action: snooze by the default length from now.
    func snooze(id: UUID, minutes: Int = SchedulerConstants.defaultSnoozeMinutes, now: Date = Date()) {
        snooze(id: id, until: now.addingTimeInterval(TimeInterval(minutes * 60)), now: now)
    }

    // MARK: - Drag & drop

    /// Returns false (UI snaps back) if the drop is not allowed.
    @discardableResult
    func moveManually(slotId: String, to newStart: Date, now: Date = Date()) -> Bool {
        guard let row = store.schedule.first(where: { $0.id == slotId }),
              var t = store.task(id: row.taskId) else { return false }

        let length = row.end.timeIntervalSince(row.start)
        let newEnd = newStart.addingTimeInterval(length)

        // Dragging a missed tile = rescheduling it by hand.
        if t.status == .missed || row.isMissed {
            if t.isFixed {
                t.fixedStart = newStart
                t.status = .pending
                store.removeRows(for: t.id)
                store.replaceTask(t)
                rerun(.fixedConflict)
                return true
            }
            return place(taskId: t.id, at: newStart, now: now)
        }

        guard t.status == .pending || t.status == .snoozed || t.status == .blocked else { return false }

        if t.isFixed {
            t.fixedStart = newStart
            store.replaceTask(t)
            rerun(.fixedConflict)
            return true
        }

        guard newStart >= now.addingTimeInterval(-60) else { return false }
        guard !hitsFixedOrPinned(newStart, newEnd, except: row.id) else { return false }

        var moved = row
        moved.start = newStart
        moved.end = newEnd
        store.replaceRow(id: row.id, with: moved)
        t.isManuallyPlaced = true
        t.snoozedUntil = nil
        t.isUnscheduled = false
        if t.status != .pending { t.status = .pending }
        store.replaceTask(t)
        rerun(.edited, now: now)
        return true
    }

    /// Pin a task (from the Unscheduled list, or a missed task) at an exact start time.
    @discardableResult
    func place(taskId: UUID, at start: Date, now: Date = Date()) -> Bool {
        guard var t = store.task(id: taskId), !t.isTemplate else { return false }
        let end = start.addingTimeInterval(TimeInterval(t.duration * 60))
        guard start >= now.addingTimeInterval(-60) else { return false }
        guard !hitsFixedOrPinned(start, end, except: nil, ignoring: taskId) else { return false }

        if t.isFixed {
            t.fixedStart = start
            t.status = .pending
            store.removeRows(for: taskId)
        } else {
            store.setRows([TaskSchedule(taskId: taskId, start: start, end: end)], for: taskId)
            t.isManuallyPlaced = true
        }
        t.isUnscheduled = false
        t.snoozedUntil = nil
        if t.status != .done { t.status = .pending }
        store.replaceTask(t)
        rerun(.edited, now: now)
        return true
    }

    /// Pin the exact segments the user dropped a splittable task onto.
    @discardableResult
    func placeSplit(taskId: UUID, segments: [(start: Date, end: Date)], now: Date = Date()) -> Bool {
        guard var t = store.task(id: taskId), !t.isFixed, segments.count > 1 else { return false }
        for s in segments {
            guard s.start >= now.addingTimeInterval(-60),
                  !hitsFixedOrPinned(s.start, s.end, except: nil, ignoring: taskId) else { return false }
        }
        let rows = segments.sorted { $0.start < $1.start }.enumerated().map {
            TaskSchedule(taskId: taskId, start: $1.start, end: $1.end, chunkIndex: $0)
        }
        store.setRows(rows, for: taskId)
        t.isManuallyPlaced = true
        t.isUnscheduled = false
        t.snoozedUntil = nil
        if t.status != .done { t.status = .pending }
        store.replaceTask(t)
        rerun(.edited, now: now)
        return true
    }

    /// Hand a pinned task back to the scheduler.
    func unlock(id: UUID) {
        guard var t = store.task(id: id), t.isManuallyPlaced else { return }
        t.isManuallyPlaced = false
        store.replaceTask(t)
        rerun(.edited)
    }

    private func hitsFixedOrPinned(_ start: Date, _ end: Date, except rowId: String?, ignoring taskId: UUID? = nil) -> Bool {
        for other in store.schedule where other.id != rowId && other.taskId != taskId && !other.isMissed {
            guard other.start < end && start < other.end, let o = store.task(id: other.taskId) else { continue }
            if o.status == .done || o.status == .missed { continue }
            if o.isFixed || o.isManuallyPlaced { return true }
        }
        return false
    }

    // MARK: - Blocked-task one-tap fixes (no UI yet; kept for later)

    func extendDeadline(id: UUID) {
        guard var t = store.task(id: id), let d = t.deadline else { return }
        t.deadline = Calendar.current.date(byAdding: .day, value: 1, to: d)
        store.replaceTask(t)
        rerun(.edited)
    }

    func shortenDuration(id: UUID, to minutes: Int) {
        guard var t = store.task(id: id), minutes >= 15, minutes < t.duration else { return }
        t.duration = minutes
        store.removeRows(for: id)
        t.isManuallyPlaced = false
        store.replaceTask(t)
        rerun(.edited)
    }

    // MARK: - Preferences

    func setDayBounds(wakeMinutes: Int, sleepMinutes: Int) {
        var p = store.preferences
        p.wakeMinutes = wakeMinutes
        p.sleepMinutes = sleepMinutes
        store.preferences = p
        rerun(.edited)
    }

    // MARK: - Fixed-time conflicts (Alert 6)

    /// Active tasks whose scheduled time collides with the slot [start, start + duration).
    /// Fixed-vs-fixed uses the raw overlap (back-to-back is fine). Flexible and pinned tasks also
    /// count when their trailing 10-minute buffer touches the slot, because the engine would move them.
    func conflictingTasks(start: Date, duration: Int,
                          excluding ids: Set<UUID> = [], now: Date = Date()) -> [AppTask] {
        let end = start.addingTimeInterval(TimeInterval(duration * 60))
        let pad = TimeInterval(SchedulerConstants.bufferMinutes * 60)
        var seen = Set<UUID>()
        var out: [AppTask] = []
        for row in store.schedule where !row.isMissed && row.end > now {
            guard !ids.contains(row.taskId), !seen.contains(row.taskId),
                  let t = store.task(id: row.taskId), !t.isTemplate,
                  t.status != .done, t.status != .missed else { continue }
            let hit = t.isFixed
                ? (row.start < end && start < row.end)
                : (row.start < end.addingTimeInterval(pad) && start < row.end.addingTimeInterval(pad))
            if hit { seen.insert(t.id); out.append(t) }
        }
        return out
    }

    // MARK: - Organize My Day (Alerts 11 and 12)

    /// Inputs for an organize pass. Manual pins and the Unscheduled flag are released and every
    /// flexible slot is cleared, so the engine plans from scratch. Left alone: fixed tasks,
    /// done/missed tasks, history, and frozen slots (in progress or starting within 15 minutes).
    /// This is the ONLY path that may move manually placed tasks, and only on an explicit request.
    private func organizeInputs(now: Date) -> (tasks: [AppTask], previous: [TaskSchedule]) {
        let lead = now.addingTimeInterval(TimeInterval(SchedulerConstants.frozenLeadMinutes * 60))
        var tasks: [AppTask] = []
        for var t in store.tasks {
            if !t.isTemplate && !t.isFixed && t.status != .done && t.status != .missed {
                t.isManuallyPlaced = false
                t.isUnscheduled = false
                if t.status == .blocked { t.status = .pending }
            }
            tasks.append(t)
        }
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let previous = store.schedule.filter { row in
            guard let t = byId[row.taskId] else { return false }
            if row.isMissed || row.end <= now || t.isFixed || t.status == .done || t.status == .missed { return true }
            return row.start <= lead
        }
        return (tasks, previous)
    }

    /// Dry run: what Organize My Day would change. Nothing is saved.
    func previewOrganize(now: Date = Date()) -> ScheduleChange {
        let (tasks, previous) = organizeInputs(now: now)
        let out = SchedulerEngine.run(SchedulerInput(tasks: tasks,
                                                     previousSchedule: previous,
                                                     preferences: store.preferences,
                                                     now: now,
                                                     calendar: .current))
        let before = ScheduleSnapshot(rows: store.schedule, tasks: store.tasks, now: now)
        let after  = ScheduleSnapshot(rows: out.schedule, tasks: tasks, now: now)
        return ScheduleSnapshot.compare(before, after)
    }

    /// Apply the reorganisation (after the user confirmed the preview).
    func organizeMyDay(now: Date = Date()) {
        let (tasks, previous) = organizeInputs(now: now)
        tasks.forEach { store.replaceTask($0) }
        store.replaceSchedule(previous)
        rerun(.edited, now: now)
    }
}
