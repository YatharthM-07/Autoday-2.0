# AutoDay 2.0 — UI + scheduler + Core Data

UI is the base project. The backend was merged INTO it (no new project).

## Layout (inside `AutoDay 2.0/AutoDay 2.0/`)
- `Models/`   AppTask, TaskSchedule, TaskEvent, UserPreferences, enums, **CoreDataModel.swift** (schema in code, no .xcdatamodeld)
- `Data/`     TaskStore (in-memory truth, write-through), **PersistenceController** (Core Data + mappers)
- `Services/` TaskService, SchedulerOrchestrator, NotificationService, EngineSlotPlanner, `Scheduler/` (engine, timeline, scorer, repeats)
- UI files at the root. `TimelineStore.swift` is now an adapter over the backend (same method names the views call).

## Backend changes made to fit the UI
- Repeat: added weekends + monthly. Importance high = urgent. Priority/colour kept per task (`colorIndex`).
- Day bounds default 07:00–23:00 (matches the timeline).
- Missed = 15 min after the slot ends. The old slot stays as a red history row (`TaskSchedule.isMissed`);
  flexible tasks get a new slot (rescheduleCount++); fixed tasks / repeat instances stay missed ("Needs rescheduling").
- Done keeps the tile full-size; the engine only blocks time up to now, so the freed slot is reusable. Undo done restores it.
- Snooze takes an exact time (Tomorrow keeps the time of day), shifts a fixed task's start, and Undo restores task + slot exactly.
- New: `TaskService.place` (drop from Unscheduled), `placeSplit` (exact dropped pieces), delete/restore snapshots.
- Fixed tasks outside the 7-day window still get a row. Fixed overlaps are still flagged, not rejected.
- Manual mode: new flexible tasks go to Unscheduled (`isUnscheduled`), engine ignores them until you drag them in.

## UI wiring (logic only, no layout/gesture/sound/haptic changes)
- `AutoDay_2_0App`: opens Core Data, configures notifications.
- `TimelineView`: real planner, Add-task saves through the store, bottom-sheet lists/counts are real.
- `DragTimelineView`: drop from the sheet uses the task's real duration.
- `MissedAlert`: MissedRule reads the backend flag; `checkMissed` runs the scheduler tick.

## Behaviour notes
- Done / Delete / Edit on a split piece applies to the whole task. Delete/Edit on a repeating tile applies to the series.
- Test tasks (ended 14 min ago / running now) now need the launch argument `-debugTestTasks` (DEBUG only).
- Not wired (no UI): Home screen, blocked/overlap banners, Insights, locations, wake/sleep screen, notification Edit deep link.

## ⚠️ Not compiled
Written without Xcode. Expect a few compile fixes on first build.
`Tests/SchedulerEngineTests.swift` is the backend's old test file; its expectations assume 08:00–22:00 bounds and the old
missed/done rules, so update it before adding it to a test target.
