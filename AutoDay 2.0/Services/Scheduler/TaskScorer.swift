// TaskScorer.swift — AutoDay · Scheduler
// Step 3: score = 0.40·P + 0.35·D + 0.15·S + 0.10·F

import Foundation

struct ScoredTask {
    let task: AppTask
    let remaining: Int            // minutes still to place
    let earliest: Date            // max(now, snoozedUntil, instance day open)
    let slackHours: Double?       // nil = no deadline
    let score: Double
    var availableMinutes: Int = 0

    /// slack <= 0: deadline overrides flexibility, goes first.
    var slackExhausted: Bool { (slackHours ?? 1) <= 0 }
}

enum TaskScorer {

    /// P — Urgent 100, Medium 60, Low 30.
    static func priorityValue(_ p: TaskPriority) -> Double {
        switch p {
        case .urgent: return 100
        case .medium: return 60
        case .low:    return 30
        }
    }

    /// D — 100 × (1 − clamp(slack / 72h, 0, 1)); no deadline → 0.
    static func deadlinePressure(slackHours: Double?) -> Double {
        guard let h = slackHours else { return 0 }
        let ratio = min(max(h / SchedulerConstants.slackWindowHours, 0), 1)
        return 100 * (1 - ratio)
    }

    /// S — min(reschedule_count, 3) × 25  (max 75).
    static func snoozeValue(_ count: Int) -> Double {
        Double(min(count, SchedulerConstants.snoozeCap)) * 25
    }

    /// F — 100 × (1 − min(duration, 120) / 120): shorter tasks get a bonus.
    static func durationFit(_ duration: Int) -> Double {
        100 * (1 - Double(min(duration, 120)) / 120)
    }

    static func score(task: AppTask, slackHours: Double?) -> Double {
        SchedulerConstants.weightPriority * priorityValue(task.priority)
        + SchedulerConstants.weightDeadline * deadlinePressure(slackHours: slackHours)
        + SchedulerConstants.weightSnooze   * snoozeValue(task.rescheduleCount)
        + SchedulerConstants.weightFit      * durationFit(task.duration)
    }

    /// Sort order: slack ≤ 0 first → score desc → earliest deadline → earliest created.
    static func outranks(_ a: ScoredTask, _ b: ScoredTask) -> Bool {
        if a.slackExhausted != b.slackExhausted { return a.slackExhausted }
        if abs(a.score - b.score) > 1e-9 { return a.score > b.score }
        let da = a.task.deadline ?? .distantFuture
        let db = b.task.deadline ?? .distantFuture
        if da != db { return da < db }
        if a.task.dateCreated != b.task.dateCreated { return a.task.dateCreated < b.task.dateCreated }
        return a.task.id.uuidString < b.task.id.uuidString
    }
}
