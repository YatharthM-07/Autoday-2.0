// TaskStore.swift — AutoDay · Data layer
// In-memory source of truth for AppTask / TaskSchedule / TaskEvent / UserPreferences.
// Every mutation is written through to Core Data (see PersistenceController), so
// the data stays on the device between launches.

import Foundation

/// A task joined with one of its schedule rows.
struct ScheduledItem: Identifiable, Hashable {
    let task: AppTask
    let slot: TaskSchedule
    var id: String { slot.id }
}

/// Everything needed to put a deleted task (or repeat series) back exactly as it was.
struct TaskSnapshot {
    var tasks: [AppTask]
    var rows: [TaskSchedule]
}

final class TaskStore {

    static let shared = TaskStore()
    private init() {}

    private(set) var tasks: [AppTask] = []
    private(set) var schedule: [TaskSchedule] = []
    private(set) var events: [TaskEvent] = []

    // Scheduler outputs
    private(set) var blocked: [BlockedTask] = []
    private(set) var fixedConflicts: [FixedConflict] = []
    private(set) var overloadedDays: [OverloadedDay] = []

    var preferences: UserPreferences = .default

    private var loaded = false

    // MARK: - Persistence

    /// Load everything saved on disk. Safe to call more than once.
    func loadFromDisk() {
        guard !loaded else { return }
        loaded = true
        let snap = PersistenceController.shared.load()
        tasks = snap.tasks
        schedule = snap.schedule
        events = snap.events
        if let p = snap.preferences { preferences = p }
    }

    /// Write-through. Called after every mutation batch.
    func persist() {
        PersistenceController.shared.save(tasks: tasks, schedule: schedule,
                                          events: events, preferences: preferences)
    }

    // MARK: - Read

    func all() -> [AppTask] { tasks }

    func task(id: UUID) -> AppTask? { tasks.first { $0.id == id } }

    func rows(for taskId: UUID) -> [TaskSchedule] {
        schedule.filter { $0.taskId == taskId }.sorted { $0.start < $1.start }
    }

    func allItems() -> [ScheduledItem] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return schedule.compactMap { row in
            guard let t = byId[row.taskId] else { return nil }
            return ScheduledItem(task: t, slot: row)
        }
    }

    func items(for day: Date) -> [ScheduledItem] {
        let cal = Calendar.current
        return allItems()
            .filter { cal.isDate($0.slot.start, inSameDayAs: day) }
            .sorted { $0.slot.start < $1.slot.start }
    }

    func nextItem(after now: Date) -> ScheduledItem? {
        let upcoming = schedule.filter { $0.end > now && !$0.isMissed }.sorted { $0.start < $1.start }
        for row in upcoming {
            if let t = task(id: row.taskId), t.status == .pending {
                return ScheduledItem(task: t, slot: row)
            }
        }
        return nil
    }

    /// Series members: the template plus every instance.
    func series(of task: AppTask) -> [AppTask] {
        let root = task.templateId ?? task.id
        return tasks.filter { $0.id == root || $0.templateId == root }
    }

    func snapshot(of ids: [UUID]) -> TaskSnapshot {
        let set = Set(ids)
        return TaskSnapshot(tasks: tasks.filter { set.contains($0.id) },
                            rows: schedule.filter { set.contains($0.taskId) })
    }

    // MARK: - Write (tasks)

    func add(_ task: AppTask) { tasks.append(task) }

    func replaceTask(_ task: AppTask) {
        guard let i = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[i] = task
    }

    func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
        schedule.removeAll { $0.taskId == id }
        events.removeAll { $0.taskId == id }
    }

    /// Put a snapshot back (delete-undo, snooze-undo).
    func restore(_ snap: TaskSnapshot) {
        for t in snap.tasks {
            if tasks.contains(where: { $0.id == t.id }) { replaceTask(t) } else { tasks.append(t) }
        }
        let ids = Set(snap.tasks.map(\.id))
        schedule.removeAll { ids.contains($0.taskId) }
        schedule.append(contentsOf: snap.rows)
    }

    // MARK: - Write (schedule)

    func removeRows(for taskId: UUID) {
        schedule.removeAll { $0.taskId == taskId }
    }

    func setRows(_ rows: [TaskSchedule], for taskId: UUID) {
        schedule.removeAll { $0.taskId == taskId }
        schedule.append(contentsOf: rows)
    }

    /// Replace the whole schedule (used by Organize My Day before the re-run).
    func replaceSchedule(_ rows: [TaskSchedule]) {
        schedule = rows
    }

    func replaceRow(id rowId: String, with newRow: TaskSchedule) {
        guard let i = schedule.firstIndex(where: { $0.id == rowId }) else { return }
        schedule[i] = newRow
    }

    /// A missed attempt: keep its rows as red history, flagged `isMissed`.
    func markRowsMissed(for taskId: UUID) {
        for i in schedule.indices where schedule[i].taskId == taskId { schedule[i].isMissed = true }
    }

    func apply(output: SchedulerOutput) {
        schedule = output.schedule
        blocked = output.blocked
        fixedConflicts = output.fixedConflicts
        overloadedDays = output.overloadedDays
        for i in tasks.indices {
            if let s = output.statusUpdates[tasks[i].id], tasks[i].status != s {
                tasks[i].status = s
            }
        }
    }

    func append(event: TaskEvent) { events.append(event) }
}
