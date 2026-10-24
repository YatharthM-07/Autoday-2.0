//
//  CompletionProgress.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26.
//
//  "3 of 5 done" + the motivational line. Pure logic, easy to unit test.
//
//  MODEL DEPENDENCY: only `make(from:on:)` reads TimelineTask (date, isDone).
//  If the backend model changes, adapt that one function.

import Foundation

struct CompletionProgress: Equatable {
    var done: Int
    var total: Int

    var ratio: Double { total > 0 ? Double(done) / Double(total) : 0 }
    var isComplete: Bool { total > 0 && done >= total }
    var remaining: Int { max(total - done, 0) }

    var message: String {
        if isComplete { return total == 1 ? "Nicely done" : "All done, nice work" }
        if (remaining == 1 && total >= 3) || ratio >= 0.75 { return "Almost there" }
        if ratio >= 0.5 { return "Halfway there" }
        if done <= 1 { return "Strong start" }
        return "Keep it going"
    }

    /// Everything scheduled on `day` counts toward the total (done, missed and pending).
    static func make(from tasks: [TimelineTask], on day: Date) -> CompletionProgress {
        let cal = Calendar.current
        let onDay = tasks.filter { cal.isDate($0.date, inSameDayAs: day) }
        return CompletionProgress(done: onDay.filter(\.isDone).count, total: onDay.count)
    }
}
