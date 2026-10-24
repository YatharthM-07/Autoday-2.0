// SchedulerEngineTests.swift — AutoDay
//
// SETUP (one time):
//   Xcode → File → New → Target → Unit Testing Bundle (name it AutoDayTests),
//   then add this file to that target. Run with ⌘U.
//
// Every test uses a fixed "now" = Monday 19 Oct 2026, 10:00, day bounds 08:00–22:00,
// so results are deterministic. The engine is pure, so no UI or store is involved.

import XCTest
@testable import AutoDay_Drag_Drop_trial

@MainActor
final class SchedulerEngineTests: XCTestCase {

    // MARK: - Helpers

    let cal = Calendar.current

    /// Monday 19 Oct 2026 + `day` days, at h:m.
    func at(_ day: Int, _ h: Int, _ m: Int = 0) -> Date {
        let base = cal.date(from: DateComponents(year: 2026, month: 10, day: 19))!
        let d = cal.date(byAdding: .day, value: day, to: base)!
        return cal.date(bySettingHour: h, minute: m, second: 0, of: d)!
    }

    var now: Date { at(0, 10) }

    func flex(_ title: String, _ dur: Int, _ p: TaskPriority = .medium, deadline: Date? = nil) -> AppTask {
        AppTask(title: title, duration: dur, priority: p, deadline: deadline)
    }

    func fixed(_ title: String, _ dur: Int, start: Date) -> AppTask {
        AppTask(title: title, duration: dur, priority: .medium, deadline: nil, isFixed: true, fixedStart: start)
    }

    func run(_ tasks: [AppTask], prev: [TaskSchedule] = [], now: Date? = nil, pull: Bool = false) -> SchedulerOutput {
        SchedulerEngine.run(SchedulerInput(tasks: tasks,
                                           previousSchedule: prev,
                                           preferences: .default,
                                           now: now ?? self.now,
                                           calendar: cal,
                                           pullForward: pull))
    }

    func rows(_ out: SchedulerOutput, _ t: AppTask) -> [TaskSchedule] {
        out.schedule.filter { $0.taskId == t.id }.sorted { $0.start < $1.start }
    }

    func dayIndex(_ d: Date) -> Int {
        cal.dateComponents([.day], from: cal.startOfDay(for: at(0, 0)), to: cal.startOfDay(for: d)).day ?? -1
    }

    // MARK: - 1. Scoring (spec §5 Step 3 and §7 numbers)

    func testScoresMatchWorkedExample() {
        var a = flex("A", 60, .urgent);  a.rescheduleCount = 0
        var b = flex("B", 120, .medium); b.rescheduleCount = 2
        let c = flex("C", 20, .low)

        XCTAssertEqual(TaskScorer.score(task: a, slackHours: 2),  79.0, accuracy: 0.1)
        XCTAssertEqual(TaskScorer.score(task: b, slackHours: 46), 44.1, accuracy: 0.1)
        XCTAssertEqual(TaskScorer.score(task: c, slackHours: nil), 20.3, accuracy: 0.1)

        a.rescheduleCount = 1   // after the 30-min snooze
        XCTAssertEqual(TaskScorer.score(task: a, slackHours: 1.5), 83.0, accuracy: 0.1)
    }

    func testSnoozeBoostIsCappedAtThree() {
        var t = flex("T", 60)
        t.rescheduleCount = 3
        let capped = TaskScorer.score(task: t, slackHours: nil)
        t.rescheduleCount = 10
        XCTAssertEqual(TaskScorer.score(task: t, slackHours: nil), capped, accuracy: 0.0001)
    }

    func testLowTaskNeverOvertakesUrgentEvenWhenMaxSnoozed() {
        var low = flex("Low", 60, .low);      low.rescheduleCount = 10
        let urgent = flex("Urgent", 60, .urgent)
        XCTAssertGreaterThan(TaskScorer.score(task: urgent, slackHours: nil),
                             TaskScorer.score(task: low, slackHours: nil))
    }

    func testTieBreakEarliestDeadlineThenEarliestCreated() {
        // Both slack > 72h → D = 0 → identical scores.
        let early = flex("early", 60, deadline: at(5, 18))
        let late  = flex("late", 60, deadline: at(6, 18))
        let s1 = ScoredTask(task: early, remaining: 60, earliest: now, slackHours: 100,
                            score: TaskScorer.score(task: early, slackHours: 100))
        let s2 = ScoredTask(task: late, remaining: 60, earliest: now, slackHours: 100,
                            score: TaskScorer.score(task: late, slackHours: 100))
        XCTAssertTrue(TaskScorer.outranks(s1, s2))
        XCTAssertFalse(TaskScorer.outranks(s2, s1))
    }

    func testSlackExhaustedAlwaysSortsFirst() {
        let tight = flex("tight", 60, .low, deadline: at(0, 11))
        let urgent = flex("urgent", 30, .urgent)
        let st = ScoredTask(task: tight, remaining: 60, earliest: now, slackHours: 0,
                            score: TaskScorer.score(task: tight, slackHours: 0))
        let su = ScoredTask(task: urgent, remaining: 30, earliest: now, slackHours: nil,
                            score: TaskScorer.score(task: urgent, slackHours: nil))
        XCTAssertTrue(TaskScorer.outranks(st, su))
    }

    // MARK: - 2. Worked example + stability (spec §7)

    func testWorkedExamplePlacement() {
        let lecture = fixed("Lecture", 90, start: at(0, 14))
        let a = flex("A", 60, .urgent, deadline: at(0, 13))
        var b = flex("B", 120, .medium, deadline: at(2, 10)); b.rescheduleCount = 2
        let c = flex("C", 20, .low)

        let out = run([lecture, a, b, c])

        XCTAssertEqual(rows(out, a).first?.start, at(0, 10))
        XCTAssertEqual(rows(out, a).first?.end,   at(0, 11))
        XCTAssertEqual(dayIndex(rows(out, b).first!.start), 1, "B has slack > 24h → day before its latest day (Tuesday)")
        XCTAssertEqual(rows(out, c).first?.start, at(0, 11, 10), "10-min buffer after A")
        XCTAssertEqual(rows(out, c).first?.end,   at(0, 11, 30))
        XCTAssertEqual(rows(out, lecture).first?.start, at(0, 14))
    }

    func testSnoozeMovesOnlyWhatMustMove() {
        let lecture = fixed("Lecture", 90, start: at(0, 14))
        var a = flex("A", 60, .urgent, deadline: at(0, 13))
        var b = flex("B", 120, .medium, deadline: at(2, 10)); b.rescheduleCount = 2
        let c = flex("C", 20, .low)

        let first = run([lecture, a, b, c])
        let bBefore = rows(first, b)

        a.rescheduleCount = 1
        a.snoozedUntil = at(0, 10, 30)
        a.status = .snoozed
        let second = run([lecture, a, b, c], prev: first.schedule)

        XCTAssertEqual(rows(second, a).first?.start, at(0, 10, 30))
        XCTAssertEqual(rows(second, a).first?.end,   at(0, 11, 30))
        XCTAssertEqual(rows(second, c).first?.start, at(0, 11, 40), "C collides with A's buffer → moves")
        XCTAssertEqual(rows(second, b), bBefore, "B must not move (stability rule)")
        XCTAssertEqual(second.statusUpdates[a.id], .snoozed)
    }

    func testRerunWithNoChangeIsIdentical() {
        let tasks = [flex("A", 60, .urgent), flex("B", 45), flex("C", 90, .low), flex("D", 30, deadline: at(3, 18))]
        let first = run(tasks)
        let second = run(tasks, prev: first.schedule)
        XCTAssertEqual(Set(first.schedule), Set(second.schedule))
    }

    // MARK: - 3. Feasibility gate (deadline violation → BLOCK)

    func testBlockedWhenNotEnoughTimeBeforeDeadline() {
        let big = flex("Big", 180, .urgent, deadline: at(0, 12))      // 3h of work, 2h available
        let other = flex("Other", 30)
        let out = run([big, other])

        XCTAssertTrue(rows(out, big).isEmpty, "blocked task is never scheduled")
        XCTAssertEqual(out.statusUpdates[big.id], .blocked)
        XCTAssertEqual(out.blocked.count, 1)
        XCTAssertTrue(out.blocked[0].canExtendDeadline)
        XCTAssertFalse(rows(out, other).isEmpty, "nothing else is dropped or touched")
    }

    func testBlockedTaskSuggestsAShorterDurationThatFits() {
        let big = flex("Big", 180, .urgent, deadline: at(0, 12))
        let out = run([big])
        let s = out.blocked[0].suggestedDuration
        XCTAssertLessThan(s, 180)
        XCTAssertGreaterThanOrEqual(s, 15)
        // Re-running with the suggested duration must succeed.
        var shorter = big; shorter.duration = s
        XCTAssertFalse(rows(run([shorter]), shorter).isEmpty)
    }

    func testDeadlineAlreadyPassedIsBlocked() {
        let t = flex("Late", 30, deadline: at(0, 9))
        XCTAssertEqual(run([t]).statusUpdates[t.id], .blocked)
    }

    func testNoDeadlineTaskNeverBlockedWhenRoomExists() {
        let t = flex("Free", 60)
        let out = run([t])
        XCTAssertTrue(out.blocked.isEmpty)
        XCTAssertEqual(out.statusUpdates[t.id], .pending)
    }

    // MARK: - 4. Fixed tasks

    func testFixedWinsAndFlexibleMovesAround() {
        let f = flex("Study", 120)
        let first = run([f])
        let oldRow = rows(first, f)[0]

        let lecture = fixed("Lecture", 120, start: oldRow.start)       // lands exactly on Study
        let second = run([f, lecture], prev: first.schedule)

        let fr = rows(second, f)[0], lr = rows(second, lecture)[0]
        XCTAssertEqual(lr.start, oldRow.start, "fixed time is never changed")
        let clear = fr.end.addingTimeInterval(600) <= lr.start || lr.end.addingTimeInterval(600) <= fr.start
        XCTAssertTrue(clear, "flexible task keeps ≥10 min clear of the fixed one")
    }

    func testTwoOverlappingFixedAreFlaggedAndBothKept() {
        let f1 = fixed("Lab", 60, start: at(0, 14))
        let f2 = fixed("Meeting", 60, start: at(0, 14, 30))
        let out = run([f1, f2])
        XCTAssertEqual(out.fixedConflicts.count, 1)
        XCTAssertEqual(rows(out, f1).count, 1)
        XCTAssertEqual(rows(out, f2).count, 1)
    }

    func testBackToBackFixedTasksAreNotAConflict() {
        let f1 = fixed("A", 60, start: at(0, 14))
        let f2 = fixed("B", 60, start: at(0, 15))
        XCTAssertTrue(run([f1, f2]).fixedConflicts.isEmpty)
    }

    // MARK: - 5. Splitting

    func testLongTaskIsSplitIntoChunksOfAtLeast30() {
        // Gaps today: 10–12, 13:10–17:00, 18:10–22:00. No single gap fits 240 + buffer.
        let f1 = fixed("F1", 60, start: at(0, 12))
        let f2 = fixed("F2", 60, start: at(0, 17))
        let long = flex("Long", 240)                      // ≥ 90 → splittable by default
        let out = run([f1, f2, long])
        let r = rows(out, long)

        XCTAssertGreaterThanOrEqual(r.count, 2)
        XCTAssertEqual(r.reduce(0) { $0 + $1.minutes }, 240)
        XCTAssertTrue(r.allSatisfy { $0.minutes >= 30 }, "min chunk = 30")
        XCTAssertEqual(Set(r.map { $0.chunkIndex }).count, r.count, "chunk indices unique")
    }

    func testSplitOverrideOffKeepsTaskWhole() {
        var long = flex("Long", 240); long.splittableOverride = false
        XCTAssertEqual(rows(run([long]), long).count, 1)
    }

    func testAutoSplitThresholdIs90() {
        XCTAssertFalse(flex("x", 89).splittable)
        XCTAssertTrue(flex("x", 90).splittable)
    }

    // MARK: - 6. Spreading overload & daily cap

    func testDeadlineTaskWithBigSlackIsNotPiledOntoToday() {
        let t = flex("Report", 60, deadline: at(3, 18))   // Thursday evening
        let day = dayIndex(rows(run([t]), t)[0].start)
        XCTAssertEqual(day, 2, "latest feasible day (Thu) minus 1 = Wednesday")
    }

    func testNoDeadlineTaskGoesToday() {
        let t = flex("Emails", 20, .low)
        XCTAssertEqual(dayIndex(rows(run([t]), t)[0].start), 0)
    }

    func testDailyCapPushesOverflowToNextDay() {
        // Today free = 10:00–22:00 → cap ≈ 80%. Five 2h tasks need 650 min with buffers; cap is ~584.
        let tasks = (1...5).map { flex("T\($0)", 120, .low) }
        let out = run(tasks)
        let today = out.schedule.filter { dayIndex($0.start) == 0 }
        let tomorrow = out.schedule.filter { dayIndex($0.start) == 1 }
        XCTAssertEqual(today.count, 4)
        XCTAssertEqual(tomorrow.count, 1)
    }

    // MARK: - 7. Preferred window (soft)

    func testPreferredWindowIsUsedWhenPossible() {
        var t = flex("Study", 60)
        t.windowStart = 14 * 60; t.windowEnd = 16 * 60
        let r = rows(run([t]), t)[0]
        XCTAssertGreaterThanOrEqual(r.start, at(0, 14))
        XCTAssertLessThanOrEqual(r.end, at(0, 16))
        XCTAssertFalse(r.windowPenalty)
    }

    func testPreferredWindowNeverBlocksScheduling() {
        let wall = fixed("Wall", 150, start: at(0, 14))       // 14:00–16:30 covers the window
        var t = flex("Study", 60)
        t.windowStart = 14 * 60; t.windowEnd = 16 * 60
        let out = run([wall, t])
        let r = rows(out, t)
        XCTAssertEqual(r.count, 1, "still scheduled")
        XCTAssertTrue(r[0].windowPenalty, "window penalty is logged")
    }

    // MARK: - 8. Buffers & deadlines hold for every row

    func testBuffersAndDeadlinesHold() {
        let tasks = [flex("a", 45, .urgent, deadline: at(0, 15)), flex("b", 60), flex("c", 30, .low),
                     flex("d", 90, deadline: at(1, 20)), flex("e", 20, .urgent), flex("f", 120, .low)]
        let out = run(tasks)

        for t in tasks {
            if let dl = t.deadline {
                XCTAssertTrue(rows(out, t).allSatisfy { $0.end <= dl }, "\(t.title) ends before its deadline")
            }
        }
        let sorted = out.schedule.sorted { $0.start < $1.start }
        for (x, y) in zip(sorted, sorted.dropFirst()) where cal.isDate(x.start, inSameDayAs: y.start) {
            XCTAssertGreaterThanOrEqual(y.start.timeIntervalSince(x.end), 600, "≥10-min buffer between rows")
        }
        XCTAssertTrue(out.schedule.allSatisfy { $0.start >= now }, "nothing planned in the past")
        XCTAssertTrue(out.schedule.allSatisfy {
            let h = cal.component(.hour, from: $0.start)
            return h >= 8 && cal.component(.hour, from: $0.end) <= 22
        }, "inside wake/sleep bounds")
    }

    // MARK: - 9. Frozen zone, pinned tasks, pull-forward

    func testTaskStartingWithin15MinutesIsFrozen() {
        let t = flex("Soon", 30)
        let prev = [TaskSchedule(taskId: t.id, start: at(0, 10, 10), end: at(0, 10, 40))]
        let u = flex("Urgent", 30, .urgent, deadline: at(0, 13))
        let out = run([t, u], prev: prev)

        XCTAssertEqual(rows(out, t).first?.start, at(0, 10, 10))
        XCTAssertGreaterThanOrEqual(rows(out, u)[0].start, at(0, 10, 50))
    }

    func testPinnedTaskIsNeverMovedAndOthersAvoidIt() {
        var p = flex("Pinned", 60); p.isManuallyPlaced = true
        let prev = [TaskSchedule(taskId: p.id, start: at(0, 11), end: at(0, 12))]
        let f = flex("Urgent", 60, .urgent)
        let out = run([p, f], prev: prev)

        XCTAssertEqual(rows(out, p).first?.start, at(0, 11))
        XCTAssertGreaterThanOrEqual(rows(out, f)[0].start, at(0, 12, 10))
    }

    func testDonePullsNonSpreadTasksForward() {
        let t = flex("Later", 30)
        let prev = [TaskSchedule(taskId: t.id, start: at(1, 9), end: at(1, 9, 30))]

        let stays = run([t], prev: prev, pull: false)
        XCTAssertEqual(dayIndex(rows(stays, t)[0].start), 1, "stability: stays without a Done")

        let pulled = run([t], prev: prev, pull: true)
        XCTAssertEqual(dayIndex(rows(pulled, t)[0].start), 0, "Done frees time → pulled forward")
    }

    // MARK: - 10. Urgent displacement / cap lift

    func testUrgentTaskStillGetsPlacedOnAFullDay() {
        // Fill today with pinned work, leave a small hole, add an urgent task due this afternoon.
        var p1 = flex("P1", 120); p1.isManuallyPlaced = true
        var p2 = flex("P2", 120); p2.isManuallyPlaced = true
        let prev = [TaskSchedule(taskId: p1.id, start: at(0, 10, 30), end: at(0, 12, 30)),
                    TaskSchedule(taskId: p2.id, start: at(0, 12, 40), end: at(0, 14, 40))]
        let u = flex("Urgent", 60, .urgent, deadline: at(0, 18))
        let out = run([p1, p2, u], prev: prev)
        XCTAssertFalse(rows(out, u).isEmpty)
        XCTAssertTrue(out.blocked.isEmpty)
    }

    // MARK: - 11. Repeats

    func testDailyTemplateGeneratesInstancesOncePerDay() {
        var tpl = flex("Gym", 45); tpl.repeatRule = .daily; tpl.dateCreated = now
        XCTAssertTrue(tpl.isTemplate)

        let first = RepeatExpander.newInstances(templates: [tpl], existing: [], now: now,
                                                preferences: .default, calendar: cal)
        XCTAssertEqual(first.count, 7)
        XCTAssertTrue(first.allSatisfy { $0.templateId == tpl.id && $0.instanceDate != nil })

        var existing = first
        existing[0].status = .missed                                 // missed instance…
        let second = RepeatExpander.newInstances(templates: [tpl], existing: existing, now: now,
                                                 preferences: .default, calendar: cal)
        XCTAssertTrue(second.isEmpty, "…is not regenerated or carried forward")
    }

    func testWeekdaysTemplateSkipsWeekend() {
        var tpl = flex("Class prep", 30); tpl.repeatRule = .weekdays; tpl.dateCreated = now
        let inst = RepeatExpander.newInstances(templates: [tpl], existing: [], now: now,
                                               preferences: .default, calendar: cal)
        XCTAssertEqual(inst.count, 5)                                // Mon–Fri
    }

    func testTemplateItselfIsNeverScheduledButInstancesAre() {
        var tpl = flex("Gym", 45); tpl.repeatRule = .daily; tpl.dateCreated = now
        let inst = RepeatExpander.newInstances(templates: [tpl], existing: [], now: now,
                                               preferences: .default, calendar: cal)
        let out = run([tpl] + inst)
        XCTAssertTrue(rows(out, tpl).isEmpty)
        for i in inst {
            let r = rows(out, i)
            XCTAssertEqual(r.count, 1)
            XCTAssertTrue(cal.isDate(r[0].start, inSameDayAs: i.instanceDate!), "instance stays on its own day")
        }
    }

    // MARK: - 12. Done / missed tasks are left alone

    func testDoneAndMissedTasksAreNotRescheduled() {
        var d = flex("Done", 30); d.status = .done
        var m = flex("Missed", 30); m.status = .missed
        let out = run([d, m])
        XCTAssertTrue(out.schedule.isEmpty)
    }
}
