// UserPreferences.swift — AutoDay · Models (replaceable)
// "User" entity: id, wake_time, sleep_time. Set once; never per task.

import Foundation

struct UserPreferences: Codable, Equatable {

    var id: UUID = UUID()
    var wakeMinutes: Int  = 7 * 60      // 07:00 (matches the UI timeline)
    var sleepMinutes: Int = 23 * 60     // 23:00

    static let `default` = UserPreferences()

    // Day bounds in minutes from midnight (sleep is forced to be after wake).
    var dayStartMinutes: Int { wakeMinutes }
    var dayEndMinutes: Int   { max(sleepMinutes, wakeMinutes + 60) }

    func dayStart(for date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .minute, value: dayStartMinutes, to: cal.startOfDay(for: date))!
    }

    func dayEnd(for date: Date) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .minute, value: dayEndMinutes, to: cal.startOfDay(for: date))!
    }
}
