// TaskSchedule.swift — AutoDay · Models (replaceable)
// "Task_Schedule" entity: one row per placed chunk of a task.

import Foundation

struct TaskSchedule: Identifiable, Codable, Hashable {
    var taskId: UUID
    var start: Date
    var end: Date
    var chunkIndex: Int = 0
    var windowPenalty: Bool = false      // preferred window was ignored for this placement
    var isMissed: Bool = false           // history row of a missed attempt (kept so the UI shows the red tile)

    /// Stable per-chunk identifier ("<taskUUID>#<chunk>").
    var id: String { "\(taskId.uuidString)#\(chunkIndex)" }

    var minutes: Int { Int((end.timeIntervalSince(start) / 60).rounded()) }
}
