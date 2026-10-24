// SchedulerOrchestrator.swift — AutoDay · Services (the "rescheduler")
// Section 4: decides WHEN the engine runs and applies its result to the store.

import Foundation

final class SchedulerOrchestrator {

    static let shared = SchedulerOrchestrator()
    private init() {}

    /// Section 4 triggers. Every case is a full re-run; `.done` also pulls tasks forward.
    enum Trigger {
        case added, edited, snoozed, missed, fixedConflict, done, dayRollover, tick
    }

    private var isRunning = false
    private var lastRunDay: Date?

    // MARK: - Run

    func run(trigger: Trigger = .edited, now: Date = Date()) {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        let store = TaskStore.shared
        let cal = Calendar.current
        store.loadFromDisk()

        // 1. Repeat templates → instances inside the horizon (Step 6)
        let templates = store.tasks.filter { $0.isTemplate }
        let fresh = RepeatExpander.newInstances(templates: templates,
                                                existing: store.tasks,
                                                now: now,
                                                preferences: store.preferences,
                                                calendar: cal)
        fresh.forEach { store.add($0) }

        // 2. Snooze expiry + missed detection
        sweep(now: now)

        // 3. Pure engine
        let input = SchedulerInput(tasks: store.tasks,
                                   previousSchedule: store.schedule,
                                   preferences: store.preferences,
                                   now: now,
                                   calendar: cal,
                                   pullForward: trigger == .done)
        store.apply(output: SchedulerEngine.run(input))
        lastRunDay = cal.startOfDay(for: now)

        // 4. Save + OS integrations
        store.persist()
        NotificationService.shared.sync(items: store.allItems(), now: now)
    }

    /// Called every ~30 s by the UI: day rollover, snooze expiry, missed tasks.
    func tick(now: Date = Date()) {
        let cal = Calendar.current
        if lastRunDay != cal.startOfDay(for: now) {
            run(trigger: .dayRollover, now: now)
            return
        }
        if sweep(now: now) { run(trigger: .missed, now: now) }
    }

    // MARK: - Sweep

    /// - Snooze time passed → task is pending again.
    /// - Slot ended and task not Done → mark missed, reschedule_count++.
    ///   Fixed tasks and repeat instances are marked missed and NOT carried forward.
    @discardableResult
    func sweep(now: Date) -> Bool {
        let store = TaskStore.shared
        var changed = false

        for var t in store.tasks where !t.isTemplate {
            var modified = false

            if t.status == .snoozed, let until = t.snoozedUntil, until <= now {
                t.status = .pending
                t.snoozedUntil = nil
                modified = true
            }

            if t.status == .pending, !t.isUnscheduled {
                let rows = store.rows(for: t.id).filter { !$0.isMissed }
                let grace = TimeInterval(SchedulerConstants.missedGraceMinutes * 60)
                if let lastEnd = rows.map({ $0.end }).max(), lastEnd.addingTimeInterval(grace) <= now {
                    store.append(event: TaskEvent(taskId: t.id, kind: .missed, date: now, minutes: 0))
                    store.markRowsMissed(for: t.id)          // old slot stays as a red history row
                    if t.isFixed || t.instanceDate != nil {
                        t.status = .missed                   // not carried forward
                    } else {
                        t.rescheduleCount += 1               // flexible: gets a fresh slot
                        t.isManuallyPlaced = false
                    }
                    modified = true
                }
            }

            if modified { store.replaceTask(t); changed = true }
        }
        return changed
    }
}
