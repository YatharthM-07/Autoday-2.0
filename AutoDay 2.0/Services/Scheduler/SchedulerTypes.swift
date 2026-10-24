// SchedulerTypes.swift — AutoDay · Scheduler
// Input / output contract of the (pure) scheduling engine.

import Foundation

struct SchedulerInput {
    var tasks: [AppTask]
    var previousSchedule: [TaskSchedule]
    var preferences: UserPreferences
    var now: Date
    var calendar: Calendar = .current
    /// Set on "Done": non-spread tasks may move earlier into the freed slot.
    var pullForward: Bool = false
}

enum BlockReason: Equatable {
    case deadlineTooTight(available: Int, needed: Int)
    case noRoomInHorizon(needed: Int)
}

struct BlockedTask: Identifiable, Equatable {
    let taskId: UUID
    let title: String
    let reason: BlockReason
    /// Duration (minutes) that would make the task fit — used by "Shorten duration".
    let suggestedDuration: Int

    var id: UUID { taskId }

    var canExtendDeadline: Bool {
        if case .deadlineTooTight = reason { return true }
        return false
    }

    var message: String {
        switch reason {
        case .deadlineTooTight: return "“\(title)”: Not enough time before the deadline"
        case .noRoomInHorizon:  return "“\(title)”: No room in the next 7 days"
        }
    }

    /// Alert 8 / 9 wording (warning banner).
    var alertMessage: String {
        switch reason {
        case .deadlineTooTight:
            return "“\(title)”: This task cannot be scheduled before its deadline with your current availability."
        case .noRoomInHorizon:
            return "“\(title)”: No suitable time slot is available in the next 7 days."
        }
    }
}

/// A day whose planned flexible work is above the 80% cap (Alert 10).
struct OverloadedDay: Identifiable, Hashable {
    let date: Date              // start of that calendar day
    let plannedMinutes: Int
    let capMinutes: Int
    var id: Date { date }
}

struct FixedConflict: Identifiable, Hashable {
    let firstId: UUID
    let secondId: UUID
    let firstTitle: String
    let secondTitle: String

    var key: String { [firstId.uuidString, secondId.uuidString].sorted().joined(separator: "|") }
    var id: String { key }
    var message: String { "“\(firstTitle)” and “\(secondTitle)” overlap" }
}

struct SchedulerOutput {
    var schedule: [TaskSchedule]
    var statusUpdates: [UUID: TaskStatus]
    var blocked: [BlockedTask]
    var fixedConflicts: [FixedConflict]
    var overloadedDays: [OverloadedDay] = []
}
