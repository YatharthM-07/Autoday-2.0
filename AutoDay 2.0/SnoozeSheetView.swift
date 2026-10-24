//  SnoozeSheetView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//

import SwiftUI
import UIKit

// MARK: - Snooze options

enum SnoozeOption: CaseIterable, Identifiable {
    case minutes15, minutes30, hour1, tomorrow

    var id: Self { self }

    var title: String {
        switch self {
        case .minutes15: return "15 minutes"
        case .minutes30: return "30 minutes"
        case .hour1:     return "1 hour"
        case .tomorrow:  return "Tomorrow"
        }
    }

    var icon: String {
        switch self {
        case .minutes15, .minutes30, .hour1: return "clock"
        case .tomorrow:                      return "sunrise.fill"
        }
    }

    /// Minutes to push the task later today. `nil` means move it to tomorrow.
    var minutes: Int? {
        switch self {
        case .minutes15: return 15
        case .minutes30: return 30
        case .hour1:     return 60
        case .tomorrow:  return nil
        }
    }

    /// Short hint shown under the title, e.g. "Moves to 12:30 PM".
    func detail(from start: Date?) -> String? {
        guard let minutes else { return "Same time, next day" }
        guard let start else { return nil }
        let target = start.addingTimeInterval(TimeInterval(minutes * 60))
        return "Moves to " + target.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - Snooze Sheet

struct SnoozeSheetView: View {
    let taskTitle: String
    /// Optional: the task's current start time, used to preview the new time.
    var taskStart: Date? = nil
    let onSelect: (SnoozeOption) -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
                .padding(.top, 14)
                .padding(.bottom, 18)

            options
                .padding(.horizontal, 20)

            cancelButton
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 12)
        }
        .padding(.top, 8)
    }

    // MARK: Pieces

    private var grabber: some View {
        Capsule()
            .fill(.secondary.opacity(0.4))
            .frame(width: 36, height: 5)
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .frame(width: 44, height: 44)
                .background(Theme.primary.opacity(0.14), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 2) {
                Text("Snooze task")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(taskTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var options: some View {
        let grid = Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                optionTile(.minutes15)
                optionTile(.minutes30)
            }
            GridRow {
                optionTile(.hour1)
                optionTile(.tomorrow)
            }
        }

        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: 10) { grid }
        } else {
            grid
        }
    }

    private func optionTile(_ option: SnoozeOption) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            onSelect(option)
        } label: {
            SnoozeTile(option: option, detail: option.detail(from: taskStart))
                .snoozeTile(tint: Theme.primary.opacity(0.10))
        }
        .buttonStyle(SnoozePressStyle())
        .accessibilityLabel(option.title)
        .accessibilityHint(option.detail(from: taskStart) ?? "")
    }

    /// Cancel sits on its own legible surface so it never dissolves into the glass.
    private var cancelButton: some View {
        Button(action: onCancel) {
            Text("Cancel")
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
                .snoozeCancelSurface()
        }
        .buttonStyle(SnoozePressStyle())
        .accessibilityLabel("Cancel")
    }
}

// MARK: - Row

private struct SnoozeTile: View {
    let option: SnoozeOption
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: option.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 28, height: 28)
                    .background(Theme.primary.opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))

                Text(option.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 72, maxHeight: .infinity,
            alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Surfaces (Liquid Glass on iOS 26, solid fallback before)

private extension View {
    @ViewBuilder
    func snoozeTile(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        if #available(iOS 26, *) {
            self.glassEffect(.regular.tint(tint).interactive(), in: shape)
        } else {
            self
                .background(Color(uiColor: .systemBackground).opacity(0.6), in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
        }
    }

    /// Cancel: capsule, high-contrast fill. Matches iOS 26 capsule controls.
    func snoozeCancelSurface() -> some View {
        self
            .background(Color(uiColor: .systemBackground).opacity(0.9), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
    }
}

// MARK: - Press style

private struct SnoozePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8),
                       value: configuration.isPressed)
    }
}
