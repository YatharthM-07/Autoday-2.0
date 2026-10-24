// RepeatExpander.swift — AutoDay · Scheduler
// Step 6: a repeat is a template that generates independent instances
// inside the horizon. Each instance is scheduled like any other task.

import Foundation

enum RepeatExpander {

    /// Instances that should exist but don't yet. Never regenerates a day that
    /// already has an instance (even done/missed), and never creates past ones —
    /// a missed instance is not carried forward.
    static func newInstances(templates: [AppTask],
                             existing: [AppTask],
                             now: Date,
                             preferences: UserPreferences,
                             calendar cal: Calendar) -> [AppTask] {
        var result: [AppTask] = []
        let sod = cal.startOfDay(for: now)

        for tpl in templates {
            guard let rule = tpl.repeatRule, tpl.templateId == nil else { continue }
            let anchor = tpl.fixedStart ?? tpl.dateCreated
            let anchorWeekday = cal.component(.weekday, from: anchor)
            let createdDay = cal.startOfDay(for: tpl.dateCreated)

            for i in 0..<SchedulerConstants.horizonDays {
                guard let day = cal.date(byAdding: .day, value: i, to: sod), day >= createdDay else { continue }

                let weekday = cal.component(.weekday, from: day)
                switch rule {
                case .daily:    break
                case .weekdays: if !(2...6).contains(weekday) { continue }
                case .weekly:   if weekday != anchorWeekday { continue }
                case .weekends: if weekday != 1 && weekday != 7 { continue }
                case .monthly:
                    // Same day-of-month as the anchor (short months: clamp to the last day).
                    let want = cal.component(.day, from: anchor)
                    let last = cal.range(of: .day, in: .month, for: day)?.count ?? 28
                    if cal.component(.day, from: day) != min(want, last) { continue }
                }

                let exists = existing.contains {
                    $0.templateId == tpl.id && $0.instanceDate.map { cal.isDate($0, inSameDayAs: day) } == true
                }
                if exists { continue }

                let close = cal.date(byAdding: .minute, value: preferences.dayEndMinutes, to: day)!
                var fixedStart: Date? = nil
                if tpl.isFixed, let f = tpl.fixedStart {
                    let c = cal.dateComponents([.hour, .minute], from: f)
                    fixedStart = cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: 0, of: day)
                    if let fs = fixedStart, fs.addingTimeInterval(TimeInterval(tpl.duration * 60)) <= now { continue }
                } else if close <= now {
                    continue
                }

                var inst = AppTask(title: tpl.title,
                                   duration: tpl.duration,
                                   priority: tpl.priority,
                                   deadline: tpl.isFixed ? nil : close,   // must happen that day
                                   isFixed: tpl.isFixed,
                                   fixedStart: fixedStart,
                                   splittableOverride: tpl.splittableOverride,
                                   repeatRule: nil,
                                   windowStart: tpl.windowStart,
                                   windowEnd: tpl.windowEnd)
                inst.templateId = tpl.id
                inst.instanceDate = day
                inst.colorIndex = tpl.colorIndex
                result.append(inst)
            }
        }
        return result
    }
}
