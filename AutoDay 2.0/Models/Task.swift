// Task.swift — AutoDay · Models (replaceable)
// Pure data. Mirrors the "Task" entity in Section 10 of the spec.
// Named AppTask so it never collides with Swift's concurrency `Task`.

import Foundation

struct AppTask: Identifiable, Codable, Hashable {

    var id: UUID = UUID()

    // ── Mandatory (3) ────────────────────────────────────────────────
    var title: String
    var duration: Int                       // minutes
    var priority: TaskPriority = .medium    // pre-selected: costs zero taps

    // ── Optional (5) ─────────────────────────────────────────────────
    var deadline: Date?                     // HARD constraint
    var isFixed: Bool = false               // HARD constraint (blocked slot)
    var fixedStart: Date?                   // required when isFixed
    var splittableOverride: Bool?           // nil = auto (ON if duration >= 90)
    var repeatRule: RepeatRule?             // non-nil on a template
    var windowStart: Int?                   // SOFT: preferred window, minutes from midnight
    var windowEnd: Int?

    // ── System-managed ───────────────────────────────────────────────
    var rescheduleCount: Int = 0
    var status: TaskStatus = .pending

    // ── Supporting fields (not in the 3+5 inputs, needed by the engine) ──
    var dateCreated: Date = Date()          // tie-break: earliest created
    var snoozedUntil: Date?                 // excluded from scheduling until then
    var isManuallyPlaced: Bool = false      // user dragged it: scheduler never moves it
    var templateId: UUID?                   // set on repeat instances
    var instanceDate: Date?                 // day an instance belongs to
    var colorIndex: Int = 0                 // UI pastel tile colour (index into PastelColor.allCases)
    var isUnscheduled: Bool = false         // Manual mode / dropped to the bottom sheet: engine leaves it alone

    // ── Derived (pure) ───────────────────────────────────────────────

    /// Auto: ON if duration >= 90 min. The toggle only overrides the default.
    var splittable: Bool { splittableOverride ?? (duration >= 90) }

    /// A repeat template generates instances and is never scheduled itself.
    var isTemplate: Bool { repeatRule != nil && templateId == nil }
}
