//
//  TimelineComponents.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  DayCell, HourRow, RescheduleTaskRow, UnscheduledTaskRow

import SwiftUI

// MARK: - Day Cell

struct DayCell: View {
    let day: Date
    let isToday: Bool
    let isSelected: Bool

    private var bg: Color {
        if isToday && isSelected { return Color(hex: "#7C5CD6") }
        if isSelected            { return Color(hex: "#EDE7FB") }
        return Color(.secondarySystemBackground)
    }
    private var numberFg: Color {
        if isToday && isSelected { return .white }
        if isToday               { return Color(hex: "#7C5CD6") }
        if isSelected            { return .black }
        return .primary
    }
    private var weekdayFg: Color {
        if isToday && isSelected { return .white.opacity(0.8) }
        if isToday               { return Color(hex: "#7C5CD6") }
        return Color(hex: "#9E9E9E")
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(day, format: .dateTime.weekday(.abbreviated))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(weekdayFg)
                .lineLimit(1)
            Text(day, format: .dateTime.day())
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(numberFg)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(bg, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isSelected && !isToday ? Color(hex: "#7C5CD6").opacity(0.35) : Color.clear,
                    lineWidth: 1.5
                )
        )
    }
}

// MARK: - Hour Row

struct HourRow: View {
    let hour: Int
    var body: some View {
        HStack(spacing: 0) {
            Text(String(format: "%02d:00", hour))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Color(hex: "#9E9E9E"))
                .frame(width: Theme.labelWidth, alignment: .trailing)
                .padding(.trailing, 8)
            Rectangle()
                .fill(Color(hex: "#E0E0E0"))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
        .frame(height: Theme.lineInset * 2)
        .frame(height: Theme.hourHeight, alignment: .top)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Reschedule Task Row

struct RescheduleTaskRow: View {
    let task: RescheduleTask
    /// Called once when the user lifts the row (Manual mode closes the sheet and shows slots).
    var onDragStart: (() -> Void)? = nil

    private func beginDrag() -> String {
        onDragStart?()
        return task.id.uuidString
    }

    var body: some View {
        let accent = TaskStatusStyle.missed.accent

        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 11, weight: .semibold))
                Text(task.scheduledTime)
                    .font(.system(size: 12))
                    .lineLimit(1)
            }
            .opacity(0.75)
        }
        .foregroundStyle(accent)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TaskStatusStyle.missed.fill)
        .overlay(alignment: .leading) {
            Rectangle().fill(accent).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .draggable(beginDrag())
    }
}

// MARK: - Unscheduled Task Row
// Draggable: carries the task's UUID string, consumed by the timeline's dropDestination.

struct UnscheduledTaskRow: View {
    let task: UnscheduledTask
    /// Called once when the user lifts the row (Manual mode uses it to close the sheet and show slots).
    var onDragStart: (() -> Void)? = nil

    /// The payload is built lazily when the drag begins, which makes it a drag-start hook.
    private func beginDrag() -> String {
        onDragStart?()
        return task.id.uuidString
    }

    private var durationText: String {
        let h = task.durationMinutes / 60, m = task.durationMinutes % 60
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title)
                .font(.system(size: 15, weight: .bold))
                .lineLimit(2)

            HStack(spacing: 4) {
                Image(systemName: "timer")
                    .font(.system(size: 11, weight: .semibold))
                Text(durationText)
                    .font(.system(size: 12))
            }
            .opacity(0.75)
        }
        .foregroundStyle(task.color.text)
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(task.color.fill)
        .overlay(alignment: .leading) {
            Rectangle().fill(task.color.text).frame(width: 4)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .draggable(beginDrag())
    }
}
