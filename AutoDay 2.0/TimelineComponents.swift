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

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: "#E5484D"))
                .frame(width: 4, height: 50)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(hex: "#E5484D"))
                HStack(spacing: 4) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(hex: "#E5484D").opacity(0.85))
                    Text(task.scheduledTime)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#E5484D").opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "#f56469").opacity(0.14),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(hex: "#f56469").opacity(0.35), lineWidth: 1)
        )
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

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3)
                .fill(task.color.text)
                .frame(width: 4, height: 40)

            Text(task.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(task.color.text)

            Spacer()

            // Visual drag hint
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12))
                .foregroundStyle(task.color.text.opacity(0.5))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(task.color.fill,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .draggable(beginDrag())
    }
}
