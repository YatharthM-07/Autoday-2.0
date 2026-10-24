//
//  SnoozeEffect.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 22/10/26.
//
//  Snooze motion (ghost trail + drifting zzz), the generalised undo stack and its toast.
//  NEW not in zip.

import SwiftUI
import UIKit

// MARK: - Undo model

struct SnoozeUndo {
    let taskID: UUID
    let oldStartHour: Double
    let oldDate: Date
}

enum UndoAction {
    case deleted(DeletedTask)
    case snoozed(SnoozeUndo)
}

struct UndoEntry: Identifiable {
    let id = UUID()
    let action: UndoAction
    let message: String
}

// MARK: - Effect model

/// Captured when the swipe starts, while the tile is still where the user saw it.
struct SnoozeContext {
    var tileFrame: CGRect     // global frame of the tile before the snooze
    var viewport: CGRect      // global frame of the visible timeline
}

struct SnoozeEffect: Identifiable {
    let id = UUID()
    let color: PastelColor
    let from: CGRect          // where the ghost trail starts
    let travel: CGFloat       // vertical distance the ghosts travel (0 when the tile leaves the view)
    let drift: CGFloat        // sideways fade-out when the tile leaves the view
    let anchor: CGRect        // where the "zzz" appears
}

// setPlacement(_:startHour:on:) now lives in TimelineStore.swift (it restores the exact snooze snapshot).

private func shortDuration(_ minutes: Int) -> String {
    minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes) min"
}

// MARK: - TimelineView glue

extension TimelineView {

    // MARK: Snooze

    /// Global frame of a tile right now. Same maths as `beginFloating`.
    func makeSnoozeContext(for task: TimelineTask, in frame: CGRect) -> SnoozeContext {
        let tile = CGRect(
            x: frame.minX + Theme.labelWidth + 24,
            y: frame.minY + topOffsetForHour(task.startHour) - scrollBox.currentY,
            width: frame.width - Theme.labelWidth - 24 - 16,
            height: max(CGFloat(task.durationHours) * Theme.hourHeight - 2, 32)
        )
        return SnoozeContext(tileFrame: tile, viewport: frame)
    }

    /// Start time of a task as a Date, for the "Moves to HH:MM" hint in the snooze sheet.
    func snoozeStartDate(for task: TimelineTask) -> Date? {
        calendar.date(byAdding: .minute,
                      value: Int((task.startHour * 60).rounded()),
                      to: calendar.startOfDay(for: task.date))
    }

    /// Applies the snooze, plays the motion and pushes the undo entry.
    func performSnooze(_ task: TimelineTask, option: SnoozeOption) {
        let oldStart = task.startHour
        let oldDate  = task.date
        let ctx      = snoozeContext
        snoozeContext = nil
        let reduceMotion = UIAccessibility.isReduceMotionEnabled

        let slide: Animation = reduceMotion
            ? .easeInOut(duration: 0.2)
            : .spring(response: 0.35, dampingFraction: 0.8)
        withAnimation(slide) { store.snooze(task.id, option: option) }

        guard let updated = store.tasks.first(where: { $0.id == task.id }) else { return }
        let movedDay = !calendar.isDate(updated.date, inSameDayAs: oldDate)
        let shift    = updated.startHour - oldStart

        // Nothing changed (already at the end of the day): no motion, no toast.
        guard movedDay || abs(shift) > 0.001 else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return
        }

        let dy = CGFloat(shift) * Theme.hourHeight
        let landsInView: Bool = {
            guard !movedDay else { return false }
            guard let ctx else { return true }
            let newMidY = ctx.tileFrame.offsetBy(dx: 0, dy: dy).midY
            return newMidY > ctx.viewport.minY && newMidY < ctx.viewport.maxY
        }()

        if !reduceMotion, let ctx {
            snoozeEffect = SnoozeEffect(
                color: task.color,
                from: ctx.tileFrame,
                travel: landsInView ? dy : 0,
                drift: landsInView ? 0 : 28,
                anchor: landsInView ? ctx.tileFrame.offsetBy(dx: 0, dy: dy) : ctx.tileFrame
            )
        }

        let message: String
        if option.minutes == nil {
            message = "“\(task.title)” snoozed to tomorrow, \(hm(updated.startHour))"
        } else if landsInView {
            message = "Snoozed \(shortDuration(Int((shift * 60).rounded())))"
        } else {
            message = "“\(task.title)” snoozed to \(hm(updated.startHour))"
        }

        pushUndo(.snoozed(SnoozeUndo(taskID: task.id, oldStartHour: oldStart, oldDate: oldDate)),
                 message: message)
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "\(message). Undo available.")
    }

    @ViewBuilder
    var snoozeLayer: some View {
        if let effect = snoozeEffect {
            SnoozeEffectLayer(effect: effect) { snoozeEffect = nil }
                .id(effect.id)
        }
    }

    // MARK: Undo stack

    func pushUndo(_ action: UndoAction, message: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            undoStack.append(UndoEntry(action: action, message: message))
            if undoStack.count > 5 { undoStack.removeFirst() }
        }
    }

    func undoLast() {
        guard let entry = undoStack.last else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            switch entry.action {
            case .deleted(let deleted):
                store.restore(deleted)
            case .snoozed(let s):
                store.setPlacement(s.taskID, startHour: s.oldStartHour, on: s.oldDate)
            }
            undoStack.removeLast()
        }
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }

    func undoToast(_ entry: UndoEntry) -> some View {
        HStack(spacing: 12) {
            if case .snoozed = entry.action {
                Image(systemName: "moon.zzz.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.primary)
                    .accessibilityHidden(true)
            }
            Text(entry.message)
                .font(.subheadline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Button("Undo") { undoLast() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.primary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .modifier(GlassCapsule())
        .padding(.horizontal, 16)
    }
}

// MARK: - Effect layer

/// Quiet by design: a short ghost trail behind the tile and a few "z" drifting up.
/// Lives above everything, never takes touches.
struct SnoozeEffectLayer: View {
    let effect: SnoozeEffect
    let onFinish: () -> Void

    @State private var moved = false

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            let from   = effect.from

            ZStack {
                // Ghost trail: starts on the old slot, lags behind the tile, fades out.
                ForEach(0..<3, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(effect.color.fill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(effect.color.text.opacity(0.35), lineWidth: 1)
                        )
                        .frame(width: from.width, height: from.height)
                        .position(x: from.midX - origin.x, y: from.midY - origin.y)
                        .offset(x: moved ? effect.drift : 0, y: moved ? effect.travel : 0)
                        .opacity(moved ? 0 : 0.34 - 0.09 * Double(i))
                        .animation(.easeOut(duration: 0.5).delay(0.06 * Double(i + 1)), value: moved)
                }

                // zzz drifting up from the tile's top-right corner.
                ZStack {
                    ForEach(0..<3, id: \.self) { i in
                        ZzzGlyph(index: i, color: effect.color.text)
                            .offset(x: CGFloat(i) * 13, y: -CGFloat(i) * 10)
                    }
                }
                .position(x: effect.anchor.maxX - 48 - origin.x,
                          y: effect.anchor.minY + 8 - origin.y)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { moved = true }
        .task {
            try? await Task.sleep(for: .seconds(1.7))
            onFinish()
        }
    }
}

private struct ZzzGlyph: View {
    let index: Int
    let color: Color

    /// 0 hidden, 1 visible, 2 drifting away
    @State private var stage = 0

    var body: some View {
        Text("z")
            .font(.system(size: CGFloat(18 + index * 6), weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .opacity(stage == 1 ? 1 : 0)
            .offset(y: stage == 2 ? -26 : 0)
            .scaleEffect(stage == 0 ? 0.6 : 1)
            .task {
                try? await Task.sleep(for: .seconds(0.25 + 0.16 * Double(index)))
                withAnimation(.easeOut(duration: 0.15)) { stage = 1 }
                try? await Task.sleep(for: .seconds(0.15))
                withAnimation(.easeOut(duration: 0.9)) { stage = 2 }
            }
    }
}
