// TaskEvent.swift — AutoDay · Models (replaceable)
// Lightweight log feeding "Progress insights" (completed, missed, snoozed, focus time).

import Foundation

enum TaskEventKind: String, Codable {
    case completed
    case missed
    case snoozed
}

struct TaskEvent: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var taskId: UUID
    var kind: TaskEventKind
    var date: Date = Date()
    var minutes: Int = 0                // focus minutes (for .completed)
}
