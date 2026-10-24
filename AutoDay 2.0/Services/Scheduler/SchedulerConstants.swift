// SchedulerConstants.swift — AutoDay · Scheduler
// Section 3 of the spec. Not user-editable: every setting is a decision,
// and decisions are what the app removes.

import Foundation

enum SchedulerConstants {
    static let horizonDays        = 7        // planning horizon
    static let bufferMinutes      = 10       // after every task
    static let dailyCapRatio      = 0.80     // of each day's free time
    static let minChunkMinutes    = 30       // smallest split piece
    static let frozenLeadMinutes  = 15       // tasks starting this soon never move
    static let slackWindowHours   = 72.0     // scale for deadline pressure
    static let spreadSlackHours   = 24.0     // slack above this -> spread across days
    static let snoozeCap          = 3        // bounds the starvation boost
    static let defaultSnoozeMinutes = 30
    static let missedGraceMinutes = 15       // a task is "missed" this long after its end
    static let gridSeconds        = 300.0    // placements snap to 5-minute marks

    // score = 0.40·P + 0.35·D + 0.15·S + 0.10·F
    static let weightPriority = 0.40
    static let weightDeadline = 0.35
    static let weightSnooze   = 0.15
    static let weightFit      = 0.10
}
