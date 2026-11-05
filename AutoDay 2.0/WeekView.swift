//
//  WeekView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 05/11/26.
//
//  Read-only landscape week view (Sun–Sat). Opened from the view menu or a pinch in.

import SwiftUI

struct WeekView: View {
    @ObservedObject var store: TimelineStore
    @Binding var selectedDate: Date
    @Binding var viewMode: TimelineViewMode
    let isMissed: (TimelineTask) -> Bool

    /// Daily capacity from the profile sheet.
    @AppStorage(ProfileKeys.capacityHours) private var capacityHours = ProfileDefaults.capacityHours

    /// Fixed Sunday-first weeks, whatever the device locale says.
    private var cal: Calendar {
        var c = Calendar.current
        c.firstWeekday = 1
        return c
    }
    private var today: Date { cal.startOfDay(for: Date()) }

    private var weekStart: Date {
        cal.dateInterval(of: .weekOfYear, for: selectedDate)?.start ?? cal.startOfDay(for: selectedDate)
    }
    private var days: [Date] {
        (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: weekStart) }
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            GeometryReader { geo in
                // Wait for the rotation to finish before laying out the grid.
                if geo.size.width > geo.size.height { content }
            }
        }
        .simultaneousGesture(
            MagnifyGesture().onEnded { if $0.magnification > 1.15 { closeToToday() } }   // pinch out
        )
    }

    // MARK: Layout

    private var content: some View {
        let days = self.days
        let byDay = tasksByDay(days)           // grouped once per render

        return VStack(spacing: 8) {
            topBar

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        dayHeader(day, tasks: byDay[day] ?? [])
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { open(day) }
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 8)

                GeometryReader { geo in
                    ScrollView(.vertical, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 6) {
                            ForEach(days, id: \.self) { day in
                                column(tasks: byDay[day] ?? [])
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .top)
                                    .contentShape(Rectangle())
                                    .onTapGesture { open(day) }
                            }
                        }
                    }
                }
            }
            // One soft card per day; today's is tinted.
            .background {
                HStack(spacing: 6) {
                    ForEach(days, id: \.self) { day in
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(cal.isDate(day, inSameDayAs: today)
                                  ? Theme.primary.opacity(0.08)
                                  : Color.primary.opacity(0.04))
                            .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            stepButton("chevron.left", label: "Previous week", by: -1)
            Text(rangeTitle)
                .font(.system(size: 17, weight: .semibold))
            stepButton("chevron.right", label: "Next week", by: 1)
            Spacer()
            Menu {
                Picker("View", selection: Binding(
                    get: { viewMode },
                    set: { newMode in if newMode == .day { closeToToday() } else { viewMode = newMode } }
                )) {
                    ForEach(TimelineViewMode.allCases, id: \.self) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
            } label: {
                Image(systemName: viewMode.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassCapsule())
            }
        }
        .padding(.top, 4)
    }

    private func stepButton(_ icon: String, label: String, by weeks: Int) -> some View {
        Button {
            if let d = cal.date(byAdding: .day, value: 7 * weeks, to: selectedDate) {
                withAnimation(.easeInOut(duration: 0.2)) { selectedDate = d }
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.primary)
                .frame(width: 32, height: 32)
                .background(Theme.primary.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    // MARK: Day header (weekday, date, stat, progress bar)

    private func dayHeader(_ day: Date, tasks: [TimelineTask]) -> some View {
        let isToday = cal.isDate(day, inSameDayAs: today)
        let p = progress(for: day, tasks: tasks)
        return VStack(spacing: 4) {
            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isToday ? Theme.primary : Theme.labelGray)
            Text(day.formatted(.dateTime.day()))
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(isToday ? Color.white : Color.primary)
                .frame(width: 30, height: 30)
                .background(isToday ? Theme.primary : Color.clear, in: Circle())
            Text(stat(for: day, tasks: tasks))
                .font(.system(size: 11))
                .foregroundStyle(Theme.labelGray)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            progressBar(value: p.value, color: p.color)
                .padding(.top, 2)
        }
    }

    /// Past days and today: share of tiles done (green).
    /// Future days: planned time against capacity (purple, amber when nearly full, red when over).
    private func progress(for day: Date, tasks: [TimelineTask]) -> (value: Double, color: Color) {
        guard !tasks.isEmpty else { return (0, .clear) }
        if cal.startOfDay(for: day) > today {
            let planned = tasks.reduce(0) { $0 + $1.durationHours }
            let v = min(planned / capacityHours, 1)
            let over = store.isOverloaded(day) || planned > capacityHours
            return (v, over ? Theme.rescheduleRed : (v > 0.85 ? Color.orange : Theme.primary))
        }
        let done = tasks.filter(\.isDone).count
        return (Double(done) / Double(tasks.count), Theme.doneGreen)
    }

    private func progressBar(value: Double, color: Color) -> some View {
        Capsule()
            .fill(Color.secondary.opacity(0.2))
            .frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { g in
                    Capsule().fill(color).frame(width: g.size.width * value)
                }
            }
            .animation(.snappy, value: value)
    }

    private func stat(for day: Date, tasks: [TimelineTask]) -> String {
        guard !tasks.isEmpty else { return "Free" }
        if cal.startOfDay(for: day) > today {
            let planned = tasks.reduce(0) { $0 + $1.durationHours }
            return "\(durationText(planned)) of \(durationText(capacityHours))"
        }
        return "\(tasks.filter(\.isDone).count) of \(tasks.count) done"
    }

    private func durationText(_ hours: Double) -> String {
        let m = Int((hours * 60).rounded())
        let h = m / 60, r = m % 60
        if h == 0 { return "\(r) min" }
        if r == 0 { return "\(h) h" }
        return "\(h) h \(r) min"
    }

    // MARK: Column

    private func column(tasks: [TimelineTask]) -> some View {
        VStack(spacing: 6) {
            if tasks.isEmpty {
                Text("Nothing planned")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.labelGray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.3),
                                          style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    )
            } else {
                ForEach(tasks) { WeekTile(task: $0, isMissed: isMissed($0)) }
            }
        }
        .padding(.bottom, 12)
    }

    // MARK: Helpers

    private func tasksByDay(_ days: [Date]) -> [Date: [TimelineTask]] {
        guard let first = days.first, let last = days.last else { return [:] }
        let end = cal.date(byAdding: .day, value: 1, to: last) ?? last
        let inWeek = store.tasks.filter { $0.date >= first && $0.date < end }
        return Dictionary(grouping: inWeek) { cal.startOfDay(for: $0.date) }
    }

    private func open(_ day: Date) {
        selectedDate = day
        viewMode = .day
    }

    /// Leaving the week view without tapping a day (pinch out, or Day in the menu) lands on today.
    private func closeToToday() {
        selectedDate = today
        viewMode = .day
    }

    private var rangeTitle: String {
        let days = self.days
        guard let first = days.first, let last = days.last else { return "" }
        if cal.isDate(first, equalTo: last, toGranularity: .month) {
            return "\(first.formatted(.dateTime.day())) to \(last.formatted(.dateTime.day().month(.wide).year()))"
        }
        if cal.isDate(first, equalTo: last, toGranularity: .year) {
            return "\(first.formatted(.dateTime.day().month(.abbreviated))) to \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
        }
        return "\(first.formatted(.dateTime.day().month(.abbreviated).year())) to \(last.formatted(.dateTime.day().month(.abbreviated).year()))"
    }
}

// MARK: - Tile

private struct WeekTile: View {
    let task: TimelineTask
    let isMissed: Bool

    /// done → missed → rescheduled → own pastel (same order as TaskBlockView)
    private var palette: (accent: Color, fill: Color) {
        if task.isDone        { return (TaskStatusStyle.done.accent,        TaskStatusStyle.done.fill) }
        if isMissed           { return (TaskStatusStyle.missed.accent,      TaskStatusStyle.missed.fill) }
        if task.isRescheduled { return (TaskStatusStyle.rescheduled.accent, TaskStatusStyle.rescheduled.fill) }
        return (task.color.text, task.color.fill)
    }

    private var marks: String {
        switch task.importance {
        case .low:    return "!"
        case .medium: return "!!"
        case .high:   return "!!!"
        }
    }

    var body: some View {
        let accent = palette.accent
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 13, weight: .bold))
                .strikethrough(task.isDone)
                .lineLimit(2)
            Text("\(hm(task.startHour)) – \(hm(task.endHour))")
                .font(.system(size: 11))
                .opacity(0.75)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                if task.isDone {
                    Image(systemName: "checkmark.circle.fill")
                } else if isMissed {
                    Image(systemName: "exclamationmark.circle.fill")
                } else if task.isRescheduled {
                    Image(systemName: "clock.arrow.circlepath")
                }
                Spacer(minLength: 0)
                Text(marks).font(.system(size: 11, weight: .heavy))
            }
            .font(.system(size: 12, weight: .bold))
            .padding(.top, 1)
        }
        .foregroundStyle(accent)
        .opacity(task.isDone ? 0.75 : 1)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.fill)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}
