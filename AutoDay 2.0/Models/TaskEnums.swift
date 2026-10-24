// TaskEnums.swift — AutoDay · Models (replaceable)
// Pure data. Foundation only. No scheduling logic, no UI.

import Foundation

/// Section 10 of the spec: pending, done, missed, snoozed, blocked.
enum TaskStatus: String, Codable, Equatable {
    case pending
    case done
    case missed
    case snoozed
    case blocked
}

/// Urgent / Medium / Low. Raw values are stable for persistence.
enum TaskPriority: Int, CaseIterable, Codable, Identifiable {
    case low    = 1
    case medium = 2
    case urgent = 3

    var id: Int { rawValue }
}

/// A repeat is a *template*; the system generates independent instances.
enum RepeatRule: String, CaseIterable, Codable, Identifiable {
    case daily
    case weekdays
    case weekly
    case weekends
    case monthly

    var id: String { rawValue }
}
