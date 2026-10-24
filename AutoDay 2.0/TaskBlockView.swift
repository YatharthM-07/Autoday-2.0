//
//  TaskBlockView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  tile's Swipe-to-done and snooze will land here.


import SwiftUI
import UIKit

// MARK: - Draggable Task Block wrapper

/// Gestures on a tile:
///  - Long press (0.4 s) → drag: reschedule on the timeline (unchanged).
///  - Horizontal swipe: right = mark done (or undo), left = snooze.
///    Runs simultaneously with the scroll view, but only locks in when the first
///    movement is horizontal, and never while a long-press drag is active.
struct DraggableTaskBlock: View {
    let task: TimelineTask
    let isBeingDragged: Bool
    let isOffDay: Bool                       // dragged in from another day: hide the original
    let onDragChanged: (CGFloat, CGPoint) -> Void   // (translation.y, global location)
    let onDragEnded:   (CGFloat) -> Void
    let onSwipeDone:   () -> Void            // right swipe past the threshold
    let onSwipeSnooze: () -> Void            // left swipe past the threshold
    let onEdit:        () -> Void            // double tap
    let onDelete:      () -> Void
    var isDimmed: Bool = false
    var isSettling: Bool = false     // hidden while the floating tile glides into place
    
    var isMissed: Bool = false                                  //NEW not in zip.
    var isShaking: Bool = false                                 //NEW not in zip.
    
    // Swipe state
    @State private var swipeX: CGFloat = 0
    @State private var swipeAxis: SwipeAxis = .undecided
    @State private var crossedThreshold = false
    @State private var isHolding = false     // long press recognised → swipe must stay out of the way

    private enum SwipeAxis { case undecided, horizontal, vertical }
    private let swipeThreshold: CGFloat = 80
    private let maxReveal: CGFloat = 130

    var body: some View {
        TaskBlockView(task: task, swipeOffset: swipeX, swipeThreshold: swipeThreshold,
                      isMissed: isMissed, isShaking: isShaking)     //NEW not in zip.
            .opacity(isOffDay || isSettling ? 0 : (isBeingDragged ? 0.35 : (isDimmed ? 0.55 : 1.0)))
            .animation(.easeOut(duration: 0.2), value: isDimmed)
            .animation(.spring(response: 0.25), value: isBeingDragged)
            .gesture(holdAndDrag)
            .simultaneousGesture(swipe)
            .simultaneousGesture(                      // ← add this
                TapGesture(count: 2).onEnded {
                    guard !isBeingDragged, !isHolding else { return }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    onEdit()
                }
            )
            .accessibilityElement(children: .combine)
            .accessibilityAction(named: "Mark done") { onSwipeDone() }
            .accessibilityAction(named: "Snooze")    { onSwipeSnooze() }
            .accessibilityAction(named: "Edit")      { onEdit() }
            .accessibilityAction(named: "Delete")    { onDelete() }
            .onChange(of: isBeingDragged) { _, dragging in
                if !dragging { isHolding = false }
            }
    }

    // MARK: Long press → drag (reschedule)

    private var holdAndDrag: some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .onChanged { value in
                switch value {
                case .second(true, let drag?):
                    isHolding = true
                    onDragChanged(drag.translation.height, drag.location)
                default:
                    break
                }
            }
            .onEnded { value in
                isHolding = false
                switch value {
                case .second(true, let drag?):
                    onDragEnded(drag.translation.height)
                default:
                    onDragEnded(0)   // cancelled — snap back
                }
            }
    }

    // MARK: Horizontal swipe (done / snooze)

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !isBeingDragged, !isHolding else { return }
                let dx = value.translation.width
                let dy = value.translation.height

                // Decide once, on the first movement, whether this is a swipe or a scroll.
                if swipeAxis == .undecided {
                    swipeAxis = abs(dx) > abs(dy) ? .horizontal : .vertical
                }
                guard swipeAxis == .horizontal else { return }

                // A done task can only be swiped right (undo); it can't be snoozed.
                let lowerBound: CGFloat = task.isDone ? 0 : -maxReveal
                swipeX = min(max(dx, lowerBound), maxReveal)

                let crossed = abs(swipeX) >= swipeThreshold
                if crossed != crossedThreshold {
                    crossedThreshold = crossed
                    if crossed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                }
            }
            .onEnded { _ in
                let shouldFire = swipeAxis == .horizontal && !isBeingDragged && !isHolding
                let x = swipeX

                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { swipeX = 0 }
                swipeAxis = .undecided
                crossedThreshold = false

                guard shouldFire else { return }
                if x >= swipeThreshold { onSwipeDone() }
                else if x <= -swipeThreshold { onSwipeSnooze() }
            }
    }
}

// MARK: - Task Block

struct TaskBlockView: View {
    let task: TimelineTask
    var swipeOffset: CGFloat = 0
    var swipeThreshold: CGFloat = 80
    
    var isMissed: Bool = false                                  //NEW not in zip.
    var isShaking: Bool = false                                 //NEW not in zip.

    var body: some View {
        let top     = topOffsetForHour(task.startHour)
        let height  = max(CGFloat(task.durationHours) * Theme.hourHeight - 2, 32)
        let compact = height < 50
        let time    = "\(hm(task.startHour)) – \(hm(task.endHour))"

        ZStack {
            if swipeOffset != 0 { swipeBackground }

            tile(compact: compact, height: height, time: time)
                .modifier(ShakeEffect(progress: isShaking ? 1 : 0))     //NEW not in zip.
                .animation(isShaking ? .linear(duration: 0.55) : nil, value: isShaking) //NEW not in zip.
                .offset(x: swipeOffset)
        }
        .frame(height: height)
        .padding(.leading, Theme.labelWidth + 24)
        .padding(.trailing, 16)
        .offset(y: top)
    }

    // MARK: Tile

    private func tile(compact: Bool, height: CGFloat, time: String) -> some View {
        let dim: Double = task.isDone ? 0.55 : 1.0

        let accent = task.isDone ? TaskStatusStyle.done.accent
                   : (isMissed ? TaskStatusStyle.missed.accent : task.color.text) //NEW not in zip.
        let fill   = task.isDone ? TaskStatusStyle.done.fill
                   : (isMissed ? TaskStatusStyle.missed.fill : task.color.fill)   //NEW not in zip.
        
        return Group {
            if compact {
                HStack(spacing: 6) {
                    Text(task.title)
                        .font(.system(size: 14, weight: .bold))
                        .strikethrough(task.isDone)
                        .opacity(dim)
                        .lineLimit(1)
                    Text(time)
                        .font(.system(size: 12))
                        .opacity(0.7 * dim)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    badges
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .top) {
                        Text(task.title)
                            .font(.system(size: 14, weight: .bold))
                            .strikethrough(task.isDone)
                            .opacity(dim)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        badges
                    }
                    Text(time)
                        .font(.system(size: 12))
                        .opacity(0.7 * dim)
                }
            }
        }
        //.foregroundStyle(task.color.text)
        .foregroundStyle(accent)//NEW not in zip.
        .padding(.leading, 22)
        .padding(.trailing, 14)
        .padding(.vertical, compact ? 0 : 10)
        .frame(maxWidth: .infinity, alignment: compact ? .leading : .topLeading)
        .frame(height: height)
        //.background(task.color.fill)
        .background(fill) //NEW not in zip.
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                //.fill(task.color.text)
                .fill(accent) //NEW not in zip.
                .frame(width: 6.5)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Swipe reveal (sits behind the tile)

    private var swipeBackground: some View {
        let isRight  = swipeOffset > 0
        let progress = min(abs(swipeOffset) / swipeThreshold, 1)
        let color    = isRight ? Theme.doneGreen : Theme.primary
        let icon     = isRight ? (task.isDone ? "arrow.uturn.backward" : "checkmark") : "zzz"
        let label    = isRight ? (task.isDone ? "Undo" : "Done") : "Snooze"

        return ZStack(alignment: isRight ? .leading : .trailing) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(color.opacity(0.25 + 0.75 * progress))

            HStack(spacing: 6) {
                Image(systemName: icon)
                Text(label)
            }
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .opacity(progress)
            .scaleEffect(progress >= 1 ? 1.08 : 1)
            .animation(.spring(response: 0.25), value: progress >= 1)
        }
    }

    // MARK: Badges

    private var badges: some View {
        HStack(spacing: 4) {
            if task.isDone {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.doneGreen)
            }
            if isMissed && !task.isDone {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.circle.fill")
                    Text("Missed")
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TaskStatusStyle.missed.accent)
            }//NEW not in zip.
            if task.isPinned { lockBadge(color: task.color.text) }
        }
    }

    private func lockBadge(color: Color) -> some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color.opacity(0.7))
            .padding(.trailing, 4)
    }
}
