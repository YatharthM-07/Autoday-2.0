//
//  TimelineStore.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  State + logic layer for the UI. This is a thin ADAPTER: it keeps the method names the views
//  already call, and turns every call into a real backend action (TaskService → SchedulerEngine,
//  saved by Core Data through TaskStore). After each action it rebuilds the tiles from the
//  scheduler's rows, so what you see is always what the scheduler decided.

import SwiftUI
import Combine
import UIKit

// MARK: - Models (what the UI renders)

/// One tile on the timeline = one schedule row of a backend task.
/// - `isPinned` – user manually placed it; shows a lock badge; blocks overlapping drops.
/// - `isFixed`  – fixed-time task; also blocks drops, no lock badge.
struct TimelineTask: Identifiable {
    var id: UUID = UUID()          // stable per schedule row (see TimelineStore.tileID)
    var title:    String
    var startHour: Double   // e.g. 9.0, 9.75
    var endHour:  Double
    let color:    PastelColor
    var isPinned: Bool = false
    var isFixed:  Bool = false
    var date: Date = Calendar.current.startOfDay(for: Date())   // the day this tile lives on
    var isDone: Bool = false

    var importance:   TaskImportance = .medium
    var deadline:     Date?          = nil
    var isSplittable: Bool           = false
    var repeatRule:   TaskRepeat     = .never

    // Backend links
    var taskID:      UUID?   = nil     // AppTask id
    var rowKey:      String? = nil     // TaskSchedule id ("<task>#<chunk>")
    var isMissedRow: Bool    = false   // backend flagged this slot as missed
    var isChunk:     Bool    = false   // one piece of a split task

    var durationHours: Double { endHour - startHour }
}

struct RescheduleTask: Identifiable {
    let id: UUID
    let title: String
    let scheduledTime: String
}

struct UnscheduledTask: Identifiable {
    let id: UUID                       // = the backend task id (the drag payload)
    let title: String
    let color: PastelColor
    var durationMinutes: Int = 60
}

struct DeletedTask {
    let task: TimelineTask
    let snapshot: TaskSnapshot
}

// MARK: - Timeline Store

@MainActor
final class TimelineStore: ObservableObject {

    @Published var tasks: [TimelineTask] = []
    @Published var unscheduled: [UnscheduledTask] = []
    @Published var reschedule: [RescheduleTask] = []

    // Scheduling alerts (see ScheduleFeedback.swift)
    @Published var toast: ScheduleToast? = nil
    @Published var warning: ScheduleWarningBanner? = nil
    @Published var dialog: ScheduleDialog? = nil
    private var knownWarnings: Set<String> = []

    private let backend = TaskStore.shared
    private let service = TaskService.shared
    private var tileIDs: [String: UUID] = [:]
    private var snoozeSnapshots: [UUID: TaskSnapshot] = [:]
    private let cal = Calendar.current

    init() {
        backend.loadFromDisk()
        #if DEBUG
        TimelineStore.seedDebugTasks()
        #endif
        SchedulerOrchestrator.shared.run(trigger: .dayRollover)   // recompute blocked / overlaps / repeats
        refresh(announceWarnings: false)                          // warnings that already exist at launch stay quiet
    }

    // MARK: - Rebuild the UI state from the backend

    func refresh(announceWarnings: Bool = true) {
        let all = backend.all().filter { !$0.isTemplate }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let templates = Dictionary(backend.all().filter { $0.isTemplate }.map { ($0.id, $0) },
                                   uniquingKeysWith: { a, _ in a })

        var rowsByTask: [UUID: [TaskSchedule]] = [:]
        for r in backend.schedule where byId[r.taskId] != nil { rowsByTask[r.taskId, default: []].append(r) }

        var out: [TimelineTask] = []
        for (taskId, rows) in rowsByTask {
            guard let t = byId[taskId] else { continue }
            let live = rows.filter { !$0.isMissed }.sorted { $0.start < $1.start }
            let rule = (t.templateId.flatMap { templates[$0]?.repeatRule } ?? t.repeatRule)
            for row in rows.sorted(by: { $0.start < $1.start }) {
                let day  = cal.startOfDay(for: row.start)
                let c    = cal.dateComponents([.hour, .minute], from: row.start)
                let sh   = Double(c.hour ?? 0) + Double(c.minute ?? 0) / 60
                var title = t.title
                var isChunk = false
                if !row.isMissed, live.count > 1, let i = live.firstIndex(where: { $0.id == row.id }) {
                    title = "\(t.title) (\(i + 1)/\(live.count))"
                    isChunk = true
                }
                out.append(TimelineTask(
                    id: tileID(for: row.id),
                    title: title,
                    startHour: sh,
                    endHour: sh + Double(row.minutes) / 60,
                    color: color(for: t),
                    isPinned: t.isManuallyPlaced && !t.isFixed,
                    isFixed: t.isFixed,
                    date: day,
                    isDone: t.status == .done,
                    importance: Self.importance(from: t.priority),
                    deadline: t.templateId == nil ? t.deadline : nil,
                    isSplittable: t.splittable,
                    repeatRule: Self.repeatRule(from: rule),
                    taskID: t.id,
                    rowKey: row.id,
                    isMissedRow: row.isMissed || t.status == .missed,
                    isChunk: isChunk
                ))
            }
        }
        out.sort { ($0.date, $0.startHour) < ($1.date, $1.startHour) }
        tasks = out

        // Unscheduled: Manual-mode tasks + tasks the scheduler blocked.
        unscheduled = all.filter { t in
            guard t.status != .done, t.status != .missed else { return false }
            let hasLiveRow = backend.rows(for: t.id).contains { !$0.isMissed }
            return !hasLiveRow && (t.isUnscheduled || t.status == .blocked)
        }
        .sorted { $0.dateCreated < $1.dateCreated }
        .map { UnscheduledTask(id: $0.id, title: $0.title, color: color(for: $0), durationMinutes: $0.duration) }

        // Needs rescheduling: missed fixed tasks and missed repeat instances.
        reschedule = all.filter { $0.status == .missed }.map { t in
            let r = backend.rows(for: t.id).last
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let when = r.map { "\(f.string(from: $0.start)) – \(f.string(from: $0.end))" } ?? ""
            return RescheduleTask(id: t.id, title: t.title, scheduledTime: when)
        }

        syncWarnings(announce: announceWarnings)
    }

    private func tileID(for rowKey: String) -> UUID {
        if let id = tileIDs[rowKey] { return id }
        let id = UUID(); tileIDs[rowKey] = id; return id
    }

    private func color(for t: AppTask) -> PastelColor {
        let all = PastelColor.allCases
        return all[((t.colorIndex % all.count) + all.count) % all.count]
    }

    private func tile(_ id: UUID) -> TimelineTask? { tasks.first { $0.id == id } }

    private func date(on day: Date, hour: Double) -> Date {
        let m = Int((hour * 60).rounded())
        return cal.date(byAdding: .minute, value: m, to: cal.startOfDay(for: day)) ?? day
    }

    // MARK: - Clock tick (day rollover, snooze expiry, missed sweep)

    /// Called from the UI's existing 30-second timer / app-open hooks.
    func tick() {
        SchedulerOrchestrator.shared.tick()
        refresh()
    }

    // MARK: - Queries

    /// True if `[start, end)` overlaps any pinned or fixed tile (except `excluding`).
    func overlapsBlocker(start: Double, end: Double, on date: Date, excluding id: UUID) -> Bool {
        tasks.contains { t in
            guard t.id != id, (t.isPinned || t.isFixed), !t.isDone, !t.isMissedRow,
                  Calendar.current.isDate(t.date, inSameDayAs: date) else { return false }
            return start < t.endHour && end > t.startHour
        }
    }

    // MARK: - Add

    /// Save from the Add Task form. Auto: the scheduler places it. Manual: it waits in Unscheduled.
    func add(_ draft: NewTaskDraft) {
        var t = makeTask(from: draft)
        t.colorIndex = Int.random(in: 0..<PastelColor.allCases.count)
        let isAuto = UserDefaults.standard.object(forKey: "isAutoMode") as? Bool ?? true
        if !isAuto, !t.isFixed, t.repeatRule == nil { t.isUnscheduled = true }

        // Alert 6: a fixed task on top of scheduled tasks asks first. Nothing is saved until confirmed.
        let newTask = t
        if confirmFixedConflict(for: newTask, confirmTitle: "Add Anyway",
                                proceed: { [weak self] in self?.commitAdd(newTask) }) { return }
        commitAdd(newTask)
    }

    private func commitAdd(_ t: AppTask) {
        let now = Date()
        let before = snapshot(now)
        service.add(t)
        let change = diff(since: before, now: now)
        refresh()

        // Alerts 1, 2, 3 (+ 7, 14). A failed placement shows NO success message: the warning banner
        // (Alerts 8 / 9) is raised by refresh() instead.
        guard let saved = backend.task(id: t.id) else { return }
        let rows = backend.rows(for: t.id).filter { !$0.isMissed }
        let primary: String?
        if saved.isTemplate                          { primary = ScheduleAlert.taskAdded }          // 1 (repeat series)
        else if saved.isUnscheduled && rows.isEmpty  { primary = ScheduleAlert.leftUnscheduled }    // 3
        else if saved.status == .blocked || rows.isEmpty { primary = nil }                          // failed
        else if saved.isFixed                        { primary = ScheduleAlert.taskAdded }          // 1
        else                                         { primary = ScheduleAlert.taskScheduled(rows: rows, now: now) }  // 2
        announce(primary, change, adjusted: ScheduleAlert.adjustedForNewTask)                        // 7 / 14
    }

    private func makeTask(from d: NewTaskDraft) -> AppTask {
        var t = AppTask(title: d.title.trimmingCharacters(in: .whitespaces), duration: d.durationMinutes)
        apply(d, to: &t)
        return t
    }

    private func apply(_ d: NewTaskDraft, to t: inout AppTask) {
        t.title = Self.stripChunkSuffix(d.title).trimmingCharacters(in: .whitespaces)
        t.priority = Self.priority(from: d.importance)
        t.splittableOverride = d.isSplittable
        t.isFixed = d.isFixed
        t.fixedStart = d.isFixed ? d.startDate : nil
        t.repeatRule = Self.repeatRule(from: d.repeatRule)
        t.deadline = (d.hasDeadline && !d.isFixed && t.repeatRule == nil) ? d.deadline : nil
    }

    // MARK: - Edit

    /// Apply an edit from the form. Edits to a repeating tile apply to the series.
    func update(_ id: UUID, from draft: NewTaskDraft) {
        guard let tile = tile(id), let tid = tile.taskID, var t = backend.task(id: tid) else { return }
        let original = t
        let tileMinutes = Int((tile.durationHours * 60).rounded())
        let keepTotal = tile.isChunk && draft.durationMinutes == tileMinutes    // untouched chunk length
        let total = keepTotal ? t.duration : draft.durationMinutes

        let wasRepeat = t.templateId != nil || t.repeatRule != nil
        let oldRule = t.repeatRule
        let oldDeadline = t.deadline
        apply(draft, to: &t)
        t.duration = max(total, 5)
        if wasRepeat {
            if t.repeatRule == nil { t.repeatRule = oldRule }      // can't un-repeat from the form
            t.deadline = oldDeadline                                // instances own their deadline
        }
        if !t.isFixed { t.fixedStart = nil }

        // Alert 6 for edits that turn a task fixed or change its fixed slot.
        let fixedSlotChanged = t.isFixed && (!original.isFixed || original.fixedStart != t.fixedStart
                                             || original.duration != t.duration)
        let edited = t
        if fixedSlotChanged,
           confirmFixedConflict(for: edited, excluding: [edited.id], confirmTitle: "Save Anyway",
                                proceed: { [weak self] in self?.commitUpdate(edited) }) { return }
        commitUpdate(edited)
    }

    private func commitUpdate(_ t: AppTask) {
        let now = Date()
        let before = snapshot(now)
        service.update(t)
        let change = diff(since: before, now: now)
        refresh()

        // Alerts 13 / 14. A repeat edit rewrites the whole series, so the edited tile's own id may be gone.
        let primary: String?
        if let task = backend.task(id: t.id), !task.isTemplate, task.templateId == nil {
            let live = backend.rows(for: t.id).filter { !$0.isMissed }
            let failed = task.status == .blocked || (live.isEmpty && !task.isUnscheduled)
            if failed {
                primary = nil                                  // no success message; 14 / warning banner explain
            } else {
                let selfChanged = change.moved.contains(t.id) || change.placed.contains(t.id)
                let othersChanged = !change.excluding([t.id]).isEmpty
                primary = (selfChanged || othersChanged) ? ScheduleAlert.updatedAdjusted : ScheduleAlert.updated
            }
        } else {
            primary = change.isEmpty ? ScheduleAlert.updated : ScheduleAlert.updatedAdjusted
        }
        announce(primary, change, adjusted: nil)               // wording for "adjusted" is already in 13
    }

    // MARK: - Drag & drop

    /// Move a tile to a new start time. Flexible tasks become pinned; fixed tasks just change start time.
    @discardableResult
    func move(_ id: UUID, to newStart: Double, on date: Date) -> Bool {
        guard let tile = tile(id), let key = tile.rowKey else { return false }
        let target = self.date(on: date, hour: newStart)
        let now = Date()
        let before = snapshot(now)
        let ok = service.moveManually(slotId: key, to: target)
        let change = diff(since: before, now: now)
        refresh()

        // Alert 5 (+ 7, 14). A refused drop (ok == false) shows nothing.
        if ok, let tid = tile.taskID {
            let row = backend.rows(for: tid).first { abs($0.start.timeIntervalSince(target)) < 1 }
            announce(ScheduleAlert.moved(start: target, end: row?.end, now: now),
                     change.excluding([tid]), adjusted: ScheduleAlert.adjusted)
        }
        return ok
    }

    /// Place an unscheduled task on the timeline (pinned) and remove it from the unscheduled list.
    @discardableResult
    func schedule(unscheduledID id: UUID, startHour: Double, on date: Date, durationHours: Double = 1.0) -> Bool {
        let target = self.date(on: date, hour: startHour)
        let now = Date()
        let before = snapshot(now)
        let ok = service.place(taskId: id, at: target)
        let change = diff(since: before, now: now)
        refresh()

        // Alert 4 (+ 7, 14). A refused drop shows nothing.
        if ok {
            announce(ScheduleAlert.placed(at: target, now: now),
                     change.excluding([id]), adjusted: ScheduleAlert.adjusted)
        }
        return ok
    }

    /// The task is dropped onto several pieces: the exact segments are pinned.
    func split(_ id: UUID, into segments: [SlotSegment], on date: Date) {
        guard let tile = tile(id), let tid = tile.taskID, segments.count > 1 else { return }
        let day = cal.startOfDay(for: date)
        let segs = segments.map { s -> (start: Date, end: Date) in
            (cal.date(byAdding: .minute, value: s.start, to: day) ?? day,
             cal.date(byAdding: .minute, value: s.end, to: day) ?? day)
        }
        let now = Date()
        let before = snapshot(now)
        let ok = service.placeSplit(taskId: tid, segments: segs)
        let change = diff(since: before, now: now)
        refresh()

        if ok {                                                // Alert 5 (+ 7, 14)
            announce(ScheduleAlert.movedToSlots(segs.count),
                     change.excluding([tid]), adjusted: ScheduleAlert.adjusted)
        }
    }

    // MARK: - Swipe actions

    /// Right swipe on a tile: mark done (or undo if already done). Applies to the whole task.
    func toggleDone(_ id: UUID) {
        guard let tile = tile(id), let tid = tile.taskID else { return }
        if tile.isDone { service.markPending(id: tid) } else { service.markDone(id: tid) }
        refresh()
    }

    /// Left swipe on a tile, then a choice in the snooze sheet.
    func snooze(_ id: UUID, option: SnoozeOption) {
        guard let tile = tile(id), let tid = tile.taskID else { return }
        let start = date(on: tile.date, hour: tile.startHour)
        let until: Date
        if let m = option.minutes {
            until = max(start, Date()).addingTimeInterval(TimeInterval(m * 60))
        } else {
            until = cal.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
        if let snap = service.snooze(id: tid, until: until) { snoozeSnapshots[id] = snap }
        refresh()
    }

    /// Undo a snooze exactly (task + slot restored); otherwise pin at the given time.
    func setPlacement(_ id: UUID, startHour: Double, on date: Date) {
        if let snap = snoozeSnapshots.removeValue(forKey: id) {
            service.restore(snap)
        } else if let tile = tile(id), let tid = tile.taskID {
            service.place(taskId: tid, at: self.date(on: date, hour: startHour))
        }
        refresh()
    }

    // MARK: - Delete / restore

    @discardableResult
    func delete(_ id: UUID) -> DeletedTask? {
        guard let tile = tile(id), let tid = tile.taskID, let snap = service.delete(id: tid) else { return nil }
        refresh()
        return DeletedTask(task: tile, snapshot: snap)
    }

    func restore(_ deleted: DeletedTask) {
        service.restore(deleted.snapshot)
        refresh()
    }

    // MARK: - Organize My Day (Alerts 11 and 12)

    /// Call this from whatever control starts "Organize My Day". It previews first (Alert 11);
    /// nothing changes until the user taps Apply. This is the only path that may move manually
    /// placed tasks. Fixed tasks never move.
    func requestOrganizeMyDay() {
        let preview = service.previewOrganize()
        let moved  = preview.moved.count + preview.lost.count
        let placed = preview.placed.count
        guard moved > 0 || placed > 0 else {
            showToast(ScheduleAlert.organizeNothingToDo, icon: "checkmark.circle")
            return
        }
        present(ScheduleDialog(title: "Organize My Day",
                               message: ScheduleAlert.organizePreview(moved: moved, placed: placed),
                               confirmTitle: "Apply",
                               confirm: { [weak self] in self?.applyOrganize() }))
    }

    private func applyOrganize() {
        let now = Date()
        let before = snapshot(now)
        service.organizeMyDay(now: now)
        let change = diff(since: before, now: now)
        refresh()
        announce(ScheduleAlert.organized, change, adjusted: nil)       // 12 (+ 14 if something could not be placed)
    }

    // MARK: - Feedback plumbing

    private func snapshot(_ now: Date) -> ScheduleSnapshot {
        ScheduleSnapshot(rows: backend.schedule, tasks: backend.tasks, now: now)
    }

    private func diff(since before: ScheduleSnapshot, now: Date) -> ScheduleChange {
        ScheduleSnapshot.compare(before, snapshot(now))
    }

    /// One toast per action: the primary message, plus either Alert 14 (a task lost its slot)
    /// or Alert 7 (other tasks moved). Success wording is only used when `primary` is non-nil.
    private func announce(_ primary: String?, _ change: ScheduleChange, adjusted: String?) {
        var parts: [String] = []
        if let primary { parts.append(primary) }
        if !change.lost.isEmpty {
            parts.append(ScheduleAlert.returnedToUnscheduled(titles: change.lost.compactMap { backend.task(id: $0)?.title }))
        } else if let adjusted, !(change.moved.isEmpty && change.placed.isEmpty) {
            parts.append(adjusted)
        }
        guard !parts.isEmpty else { return }
        showToast(parts.joined(separator: " "),
                  icon: primary == nil ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
    }

    /// Alert 6. Returns true if a dialog was raised (the caller must stop and wait for the answer).
    private func confirmFixedConflict(for t: AppTask,
                                      excluding ids: Set<UUID> = [],
                                      confirmTitle: String,
                                      proceed: @escaping () -> Void) -> Bool {
        guard t.isFixed, t.repeatRule == nil, t.templateId == nil, let start = t.fixedStart else { return false }
        let conflicts = service.conflictingTasks(start: start, duration: t.duration, excluding: ids)
        guard !conflicts.isEmpty else { return false }
        let hasProtected = conflicts.contains { $0.isFixed || $0.isManuallyPlaced }
        // Delayed so the Add / Edit sheet has finished dismissing before the dialog appears.
        present(ScheduleDialog(title: "Time conflict",
                               message: ScheduleAlert.fixedConflict(count: conflicts.count, hasProtected: hasProtected),
                               confirmTitle: confirmTitle,
                               confirm: proceed),
                after: 0.5)
        return true
    }

    private func present(_ d: ScheduleDialog, after delay: TimeInterval = 0) {
        if delay <= 0 { dialog = d; return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.dialog = d
        }
    }

    // MARK: Toast

    func showToast(_ text: String, icon: String = "checkmark.circle.fill") {
        let t = ScheduleToast(text: text, icon: icon)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { toast = t }
        UIAccessibility.post(notification: .announcement, argument: text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard self?.toast?.id == t.id else { return }          // a newer toast replaced it
            withAnimation(.easeInOut) { self?.toast = nil }
        }
    }

    func dismissToast() { withAnimation(.easeInOut) { toast = nil } }

    // MARK: Warning banner (Alerts 8, 9, 10)

    /// Raises a banner when a warning appears that was not there before. A warning that stays true
    /// is not repeated every refresh; if it clears and comes back, it is announced again.
    private func syncWarnings(announce: Bool) {
        var current: [(key: String, text: String)] = []
        for b in backend.blocked {                                     // 8 and 9
            current.append(("blocked:\(b.taskId.uuidString):\(b.canExtendDeadline ? "deadline" : "noslot")",
                            b.alertMessage))
        }
        for d in backend.overloadedDays {                              // 10
            current.append(("cap:\(Int(d.date.timeIntervalSince1970))", ScheduleAlert.capacity(day: d.date)))
        }
        let fresh = current.filter { !knownWarnings.contains($0.key) }
        knownWarnings = Set(current.map(\.key))
        guard announce, let first = fresh.first else { return }

        let w = ScheduleWarningBanner(text: first.text, extra: fresh.count - 1)
        withAnimation(.easeInOut(duration: 0.3)) { warning = w }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        UIAccessibility.post(notification: .announcement, argument: first.text)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(7))
            guard self?.warning?.id == w.id else { return }
            withAnimation(.easeInOut) { self?.warning = nil }
        }
    }

    func dismissWarning() { withAnimation(.easeInOut) { warning = nil } }

    // MARK: - Mapping helpers

    static func importance(from p: TaskPriority) -> TaskImportance {
        switch p { case .low: return .low; case .medium: return .medium; case .urgent: return .high }
    }
    static func priority(from i: TaskImportance) -> TaskPriority {
        switch i { case .low: return .low; case .medium: return .medium; case .high: return .urgent }
    }
    static func repeatRule(from r: RepeatRule?) -> TaskRepeat {
        switch r {
        case .none: return .never
        case .some(.daily): return .daily
        case .some(.weekdays): return .weekdays
        case .some(.weekends): return .weekends
        case .some(.weekly): return .weekly
        case .some(.monthly): return .monthly
        }
    }
    static func repeatRule(from r: TaskRepeat) -> RepeatRule? {
        switch r {
        case .never: return nil
        case .daily: return .daily
        case .weekdays: return .weekdays
        case .weekends: return .weekends
        case .weekly: return .weekly
        case .monthly: return .monthly
        }
    }
    /// "Study (2/3)" -> "Study". The suffix is display-only.
    static func stripChunkSuffix(_ s: String) -> String {
        s.replacingOccurrences(of: #"\s\(\d+/\d+\)$"#, with: "", options: .regularExpression)
    }
}

// MARK: - Debug test tasks (opt-in)

extension TimelineStore {
    /// Launch with the argument `-debugTestTasks` (Edit Scheme ▸ Run ▸ Arguments) to add tasks
    /// placed relative to "now", so the missed alert can be tested without waiting.
    static func seedDebugTasks() {
        #if DEBUG
        guard CommandLine.arguments.contains("-debugTestTasks") else { return }
        let store = TaskStore.shared
        guard !store.all().contains(where: { $0.title == "Test: ended 14 min ago" }) else { return }
        let now = Date()
        var a = AppTask(title: "Test: ended 14 min ago", duration: 60)
        a.isFixed = true; a.fixedStart = now.addingTimeInterval(-74 * 60); a.colorIndex = 7
        var b = AppTask(title: "Test: running now", duration: 60)
        b.isFixed = true; b.fixedStart = now.addingTimeInterval(-15 * 60); b.colorIndex = 8
        store.add(a); store.add(b)
        #endif
    }
}
