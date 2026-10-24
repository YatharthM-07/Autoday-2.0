// ScheduleFeedback.swift — AutoDay · Services


import SwiftUI
import UIKit

// MARK: - Models

struct ScheduleToast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    var icon: String = "checkmark.circle.fill"
}

struct ScheduleWarningBanner: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let extra: Int            // how many more new warnings arrived with this one
}

struct ScheduleDialog: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let confirm: () -> Void
    var cancel: (() -> Void)? = nil
}

// MARK: - Wording (the 14 alerts)

enum ScheduleAlert {

    // 1  Task Added Successfully
    static let taskAdded = "Task added successfully."

    // 2  Task Scheduled Successfully
    static func taskScheduled(rows: [TaskSchedule], now: Date = Date()) -> String {
        let sorted = rows.sorted { $0.start < $1.start }
        guard let first = sorted.first else { return taskAdded }
        if sorted.count > 1 {
            return "Your task has been split into \(sorted.count) sessions, starting \(FeedbackText.when(first.start, first.end, now: now))."
        }
        return "Your task has been scheduled for \(FeedbackText.when(first.start, first.end, now: now))."
    }

    // 3  Task Left Unscheduled
    static let leftUnscheduled = "Task added to your unscheduled list. Place it on your timeline when ready."

    // 4  Task Placed on Timeline
    static func placed(at start: Date, now: Date = Date()) -> String {
        "Task scheduled for \(FeedbackText.whenStart(start, now: now))."
    }

    // 5  Task Rescheduled
    static func moved(start: Date, end: Date?, now: Date = Date()) -> String {
        if let end { return "Task moved to \(FeedbackText.when(start, end, now: now))." }
        return "Task moved to \(FeedbackText.whenStart(start, now: now))."
    }
    static func movedToSlots(_ count: Int) -> String { "Task moved to \(count) time slots." }

    // 6  Fixed-Time Conflict (confirmation dialog)
    static func fixedConflict(count: Int, hasProtected: Bool) -> String {
        let n = count == 1 ? "1 scheduled task" : "\(count) scheduled tasks"
        let head = "This time conflicts with \(n)."
        return hasProtected
            ? head + " Fixed and manually placed tasks stay where they are; other tasks will be moved."
            : head + " They will be rescheduled around it."
    }

    // 7  Schedule Adjusted Automatically
    static let adjustedForNewTask = "Your schedule was adjusted to fit the new task."
    static let adjusted           = "Your schedule was adjusted."

    // 8 / 9  Warning banner wording lives on BlockedTask.alertMessage (SchedulerTypes.swift).

    // 10  Daily Capacity Exceeded
    static func capacity(day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Your planned tasks exceed today's available working time."
        }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return "Your planned tasks exceed \(f.string(from: day))'s available working time."
    }

    // 11  Organize My Day: Preview (confirmation dialog)
    static func organizePreview(moved: Int, placed: Int) -> String {
        var parts: [String] = []
        if moved > 0  { parts.append("move \(moved) \(moved == 1 ? "task" : "tasks")") }
        if placed > 0 { parts.append("place \(placed) unscheduled \(placed == 1 ? "task" : "tasks")") }
        return "Organizing your day will \(parts.joined(separator: " and ")). Apply changes?"
    }
    static let organizeNothingToDo = "Your day is already organized."

    // 12  Organize My Day: Success
    static let organized = "Your schedule has been reorganized."

    // 13  Task Updated & Rescheduled
    static let updated         = "Task updated."
    static let updatedAdjusted = "Task updated. Your schedule has been adjusted."

    // 14  Task Returned to Unscheduled
    static func returnedToUnscheduled(titles: [String]) -> String {
        if titles.count == 1 { return "“\(titles[0])” moved to your unscheduled list." }
        if titles.isEmpty    { return "Task moved to your unscheduled list." }
        return "\(titles.count) tasks moved to your unscheduled list."
    }
}

// MARK: - Time formatting

enum FeedbackText {

    static func time(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: d)
    }

    static func range(_ s: Date, _ e: Date) -> String {
        let f = DateIntervalFormatter(); f.dateStyle = .none; f.timeStyle = .short
        return f.string(from: s, to: e)
    }

    /// "tomorrow", "Tue 21 Oct" or nil for today.
    static func dayPrefix(_ d: Date, now: Date, calendar cal: Calendar = .current) -> String? {
        if cal.isDate(d, inSameDayAs: now) { return nil }
        if let t = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: t) { return "tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"
        return f.string(from: d)
    }

    /// "4:00 – 5:00 PM", with the day in front when it is not today.
    static func when(_ s: Date, _ e: Date, now: Date) -> String {
        [dayPrefix(s, now: now), range(s, e)].compactMap { $0 }.joined(separator: ", ")
    }

    static func whenStart(_ s: Date, now: Date) -> String {
        [dayPrefix(s, now: now), time(s)].compactMap { $0 }.joined(separator: ", ")
    }
}

// MARK: - Schedule diff

/// What changed for OTHER tasks after a scheduler run. Fixed tasks are ignored (they never move
/// on their own). A task that is new, deleted, done or missed is ignored too.
struct ScheduleChange {
    var moved:  [UUID] = []     // had a slot, now has a different one
    var placed: [UUID] = []     // had no slot, now has one
    var lost:   [UUID] = []     // had a slot, now has none → Unscheduled list (Alert 14)

    var isEmpty: Bool { moved.isEmpty && placed.isEmpty && lost.isEmpty }

    func excluding(_ ids: Set<UUID>) -> ScheduleChange {
        ScheduleChange(moved:  moved.filter  { !ids.contains($0) },
                       placed: placed.filter { !ids.contains($0) },
                       lost:   lost.filter   { !ids.contains($0) })
    }
}

/// The live (future, non-missed) slots of every active flexible task, at one moment.
struct ScheduleSnapshot {
    private struct Slot: Hashable { let start: Int; let end: Int }
    private var slots: [UUID: [Slot]] = [:]
    private var active: Set<UUID> = []

    init(rows: [TaskSchedule], tasks: [AppTask], now: Date) {
        for t in tasks where !t.isTemplate && !t.isFixed && t.status != .done && t.status != .missed {
            active.insert(t.id)
        }
        for r in rows where !r.isMissed && r.end > now && active.contains(r.taskId) {
            slots[r.taskId, default: []].append(Slot(start: Int(r.start.timeIntervalSince1970),
                                                     end: Int(r.end.timeIntervalSince1970)))
        }
        for k in slots.keys { slots[k]?.sort { $0.start < $1.start } }
    }

    static func compare(_ before: ScheduleSnapshot, _ after: ScheduleSnapshot) -> ScheduleChange {
        var c = ScheduleChange()
        for id in before.active where after.active.contains(id) {
            let b = before.slots[id] ?? []
            let a = after.slots[id] ?? []
            if b.isEmpty && !a.isEmpty      { c.placed.append(id) }
            else if !b.isEmpty && a.isEmpty { c.lost.append(id) }
            else if !b.isEmpty && b != a    { c.moved.append(id) }
        }
        return c
    }
}

// MARK: - Views (hooked into TimelineView with three one-line insertions)

extension TimelineView {

    /// Toast above the Tasks sheet. Same glass capsule as the undo toast. Tap to dismiss.
    @ViewBuilder
    var scheduleToast: some View {
        if let toast = store.toast {
            Button { store.dismissToast() } label: {
                HStack(spacing: 10) {
                    Image(systemName: toast.icon)
                        .font(.subheadline)
                        .foregroundStyle(Theme.primary)
                        .accessibilityHidden(true)
                    Text(toast.text)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
                .frame(minHeight: 48)
                .modifier(GlassCapsule())
                .padding(.horizontal, 16)
            }
            .buttonStyle(.plain)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// Warning banner under the date strip, built like the missed banner. Tap to dismiss.
    @ViewBuilder
    var scheduleWarningBanner: some View {
        if let w = store.warning {
            let accent = Theme.rescheduleText
            let shape  = RoundedRectangle(cornerRadius: 14, style: .continuous)
            Button { store.dismissWarning() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(accent)
                        .frame(width: 26, height: 26)
                        .background(accent.opacity(0.14), in: Circle())
                    Text(w.extra > 0 ? "\(w.text) (+\(w.extra) more)" : w.text)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(3)
                    Spacer(minLength: 8)
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(accent)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(minHeight: 48)
                .background(Color(uiColor: .systemBackground), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .accessibilityHint("Dismisses this warning")
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }
}

/// System confirmation dialog for Alert 6 (fixed-time conflict) and Alert 11 (Organize My Day).
struct ScheduleDialogModifier: ViewModifier {
    @ObservedObject var store: TimelineStore

    func body(content: Content) -> some View {
        content.confirmationDialog(
            store.dialog?.title ?? "",
            isPresented: Binding(get: { store.dialog != nil },
                                 set: { if !$0 { store.dialog = nil } }),
            titleVisibility: .visible,
            presenting: store.dialog
        ) { d in
            Button(d.confirmTitle) { d.confirm() }
            Button("Cancel", role: .cancel) { d.cancel?() }
        } message: { d in
            Text(d.message)
        }
    }
}

extension View {
    func scheduleDialogs(_ store: TimelineStore) -> some View {
        modifier(ScheduleDialogModifier(store: store))
    }
}
