//
//  DragTimelineView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 21/10/26.
//
//  Drag, auto-scroll, edge-flip logic, slot placeholders, floating tile, trash + undo

import SwiftUI
import UIKit

extension TimelineView {

    // MARK: - Visible tasks

    /// Tasks on the selected day, plus the one being dragged (kept alive across day flips
    /// so its gesture isn't cancelled when the day changes under the finger).
    var visibleTasks: [TimelineTask] {
        store.tasks.filter {
            calendar.isDate($0.date, inSameDayAs: selectedDate) || $0.id == draggedTaskId
        }
    }

    // MARK: - Drag handlers

    func handleDragChanged(task: TimelineTask, deltaY: CGFloat, location: CGPoint, frame: CGRect) {
        if !scrollBox.dragging {
            scrollBox.dragging = true
            scrollBox.dragStartY = scrollBox.currentY
            scrollBox.startLocation = location
            beginFloating(task, in: frame)
        }
        draggedTaskId = task.id
        scrollBox.lastTranslation = deltaY
        scrollBox.dragStartHour   = task.startHour
        scrollBox.dragDuration    = task.durationHours
        scrollBox.lastLocation    = location
        scrollBox.timelineTop     = frame.minY

        // The floating tile follows the finger freely (x and y).
        dragTranslation = CGSize(width: location.x - scrollBox.startLocation.x,
                                 height: location.y - scrollBox.startLocation.y)

        // Trash target: generous hit area, haptic on enter/leave.
        let overTrash = trashFrame.insetBy(dx: -12, dy: -12).contains(location)
        if overTrash != isOverTrash {
            isOverTrash = overTrash
            if overTrash { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            else         { UISelectionFeedbackGenerator().selectionChanged() }
        }

        // Above the timeline (header / date strip): no placeholders, day flip or auto-scroll,
        // so travelling to the trash doesn't flip days or scroll.
        if location.y < frame.minY {
            ghostHour = nil
            cancelEdgeFlip()
            stopAutoScroll()
            return
        }

        refreshGhost()
        updateEdgeFlip(globalX: location.x, width: frame.width)
        updateAutoScroll(globalY: location.y, frame: frame)
    }

    /// Pick-up: haptic, floating copy, and the candidate slots for this task.
    private func beginFloating(_ task: TimelineTask, in frame: CGRect) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        dragOriginFrame = CGRect(
            x: frame.minX + Theme.labelWidth + 24,
            y: frame.minY + topOffsetForHour(task.startHour) - scrollBox.currentY,
            width: frame.width - Theme.labelWidth - 24 - 16,
            height: max(CGFloat(task.durationHours) * Theme.hourHeight - 2, 32)
        )
        dragTranslation = .zero
        floatingTask = task
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            slotPlans = planner.plans(for: task, on: selectedDate, among: store.tasks, now: Date())
        }
    }

    /// Day flipped mid-drag: recompute the candidate slots for the new day.
    func refreshSlotPlans() {
        guard let task = floatingTask, draggedTaskId != nil else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            slotPlans = planner.plans(for: task, on: selectedDate, among: store.tasks, now: Date())
        }
    }

    /// Recomputes the snapped proposal from finger travel + how far the content has scrolled.
    func refreshGhost() {
        let eff       = scrollBox.lastTranslation + scrollBox.scrollDelta
        let rawMins   = hoursToMinutes(scrollBox.dragStartHour) + Int(eff / kPPM)
        let snapped   = snappedMinutes(rawMins)
        let clamped   = min(max(snapped, kTimelineStartMinutes),
                            kTimelineEndMinutes - hoursToMinutes(scrollBox.dragDuration))
        ghostHour = minutesToHours(clamped)
    }

    /// The plan the finger is currently on (nil = nothing to drop on).
    var activePlacement: SlotPlan? {
        guard draggedTaskId != nil, !isOverTrash, let g = ghostHour else { return nil }
        return resolvePlacement(plans: slotPlans,
                                proposedStart: toMinutes(g),
                                duration: toMinutes(scrollBox.dragDuration))
    }

    /// Haptic when the finger moves onto a (different) placeholder.
    func activePlacementChanged(_ id: UUID?) {
        guard id != nil else { return }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func handleDragEnded(task: TimelineTask, deltaY: CGFloat) {
        let overTrash     = isOverTrash
        let aboveTimeline = scrollBox.lastLocation.y < scrollBox.timelineTop
        let placement     = activePlacement
        let dayChanged    = !calendar.isDate(task.date, inSameDayAs: selectedDate)
        let targetDate    = selectedDate
        let wasFloating   = floatingTask != nil

        defer {
            draggedTaskId = nil
            ghostHour = nil
            isOverTrash = false
            cancelEdgeFlip()
            stopAutoScroll()
            scrollBox.dragging = false
            withAnimation(.easeOut(duration: 0.15)) { slotPlans = [] }
        }

        // A long press that never turned into a drag: nothing to do.
        guard wasFloating else { return }

        // 1. Dropped on the trash.
        if overTrash {
            deleteTask(task)
            withAnimation(.easeIn(duration: 0.18)) { floatingTask = nil }
            return
        }

        // 2. Released over the header, or on no placeholder: glide back to where it came from.
        guard !aboveTimeline, let placement else {
            if dayChanged { withAnimation(.easeInOut(duration: 0.25)) { selectedDate = task.date } }
            if !aboveTimeline { UINotificationFeedbackGenerator().notificationOccurred(.error) }
            settleFloatingTile(toStartMinutes: toMinutes(task.startHour)) {}
            return
        }

        switch placement.kind {

        // 3. Fits whole: glide into the slot, then commit.
        case .whole:
            let seg = placement.segments[0]

            // A hold without movement must not pin the task.
            if !dayChanged && seg.start == toMinutes(task.startHour) {
                settleFloatingTile(toStartMinutes: seg.start) {}
                return
            }
            settleFloatingTile(toStartMinutes: seg.start) {
                // No animation here: the real tile is hidden until the floating one is removed,
                // so it appears already in place.
                store.move(task.id, to: minutesToHours(seg.start), on: targetDate)
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            }

        // 4. Split: the tile breaks into its pieces.
        case .split:
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                store.split(task.id, into: placement.segments, on: targetDate)
                floatingTask = nil
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        }
    }

    /// Glides the floating tile to `minutes` on the timeline (where it will really land),
    /// then runs `completion` and removes the floating copy.
    func settleFloatingTile(toStartMinutes minutes: Int, completion: @escaping () -> Void) {
        let targetY = scrollBox.timelineTop + topOffsetForHour(Double(minutes) / 60) - scrollBox.currentY
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            dragTranslation = CGSize(width: 0, height: targetY - dragOriginFrame.minY)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            completion()
            if draggedTaskId == nil { floatingTask = nil }
        }
    }

    // MARK: - Floating layer, hints

    /// The picked-up tile. Lives above everything, so it can hover over other tiles and reach the trash.
    @ViewBuilder
    var floatingLayer: some View {
        if let task = floatingTask {
            GeometryReader { geo in
                let origin = geo.frame(in: .global).origin
                FloatingTaskTile(task: task,
                                 timeText: floatingTimeText(for: task),
                                 compact: dragOriginFrame.height < 50,
                                 isOverTrash: isOverTrash)
                    .frame(width: dragOriginFrame.width, height: dragOriginFrame.height)
                    .position(x: dragOriginFrame.midX + dragTranslation.width - origin.x,
                              y: dragOriginFrame.midY + dragTranslation.height - origin.y)
            }
            .allowsHitTesting(false)
            .transition(.scale(scale: 0.5).combined(with: .opacity))
        }
    }

    func floatingTimeText(for task: TimelineTask) -> String {
        if let plan = activePlacement {
            if plan.kind == .whole, let s = plan.segments.first {
                return "\(clock(s.start)) – \(clock(s.end))"
            }
            return "Splits into \(plan.segments.count) parts"
        }
        return "\(hm(task.startHour)) – \(hm(task.endHour))"
    }

    /// Shown at the top of the timeline when the task can't go anywhere on this day.
    @ViewBuilder
    var noSlotCapsule: some View {
        if draggedTaskId != nil, slotPlans.isEmpty, ghostHour != nil, !isOverTrash {
            Label("No free slot on this day", systemImage: "calendar.badge.exclamationmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .modifier(GlassCapsule())
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: - Delete / undo

//    func deleteTask(_ task: TimelineTask) {
//        UINotificationFeedbackGenerator().notificationOccurred(.success)
//        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
//            if let removed = store.delete(task.id) { undoItem = removed }
//        }
//        UIAccessibility.post(notification: .announcement,
//                             argument: "\(task.title) deleted. Undo available.")
//    }
    
    func deleteTask(_ task: TimelineTask) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let removed = store.delete(task.id) {
                pushUndo(.deleted(removed), message: "“\(task.title)” deleted")   //NEW not in zip.
            }
        }
        UIAccessibility.post(notification: .announcement,
                             argument: "\(task.title) deleted. Undo available.")
    }
    
    //undoLast() has replaced the below func.

//    func undoDelete() {
//        guard let item = undoItem else { return }
//        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
//            store.restore(item)
//            undoItem = nil
//        }
//    }

    // MARK: Vertical auto-scroll (drag near the top/bottom of the timeline)

    func updateAutoScroll(globalY: CGFloat, frame: CGRect) {
        let topZone: CGFloat    = 70     // hot zone height at the top of the timeline
        let bottomZone: CGFloat = 150    // taller at the bottom: the Tasks sheet covers part of it
        let maxSpeed: CGFloat   = 700    // pt per second at the very edge

        let topEdge    = frame.minY + topZone
        let bottomEdge = frame.maxY - bottomZone

        var v: CGFloat = 0
        if globalY < topEdge {
            v = -maxSpeed * min(1, (topEdge - globalY) / topZone)
        } else if globalY > bottomEdge {
            v = maxSpeed * min(1, (globalY - bottomEdge) / bottomZone)
        }
        scrollBox.velocity = v
        if v != 0 { startAutoScroll() } else { stopAutoScroll() }
    }

    func startAutoScroll() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
            guard let sv = scrollBox.sv, scrollBox.velocity != 0 else { return }
            let minY = -sv.adjustedContentInset.top
            let maxY = max(minY, sv.contentSize.height - sv.bounds.height + sv.adjustedContentInset.bottom)
            let newY = min(max(sv.contentOffset.y + scrollBox.velocity / 60.0, minY), maxY)
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: newY), animated: false)
            refreshGhost()   // keep the proposal under the finger while the content moves
        }
        RunLoop.main.add(timer, forMode: .common)   // .common so it keeps firing during touch tracking
        autoScrollTimer = timer
    }

    func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        scrollBox.velocity = 0
    }

    // MARK: Edge-hold day flip (drag a block to the screen edge to change day)

    func updateEdgeFlip(globalX: CGFloat, width: CGFloat) {
        let edge: CGFloat = 44
        let dir = globalX < edge ? -1 : (globalX > width - edge ? 1 : 0)
        guard dir != edgeDirection else { return }
        edgeDirection = dir
        edgeWork?.cancel()
        if dir != 0 { scheduleEdgeFlip(dir) }
    }

    func scheduleEdgeFlip(_ dir: Int) {
        let work = DispatchWorkItem {
            guard draggedTaskId != nil, edgeDirection == dir else { return }
            moveDay(by: dir)
            scheduleEdgeFlip(dir)   // keep flipping while held at the edge
        }
        edgeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
    }

    func cancelEdgeFlip() {
        edgeWork?.cancel()
        edgeWork = nil
        edgeDirection = 0
    }

    // MARK: External drop (bottom sheet → timeline)

    /// Handle a drop from the bottom sheet.
    /// `dropLocation` is in the ScrollView's frame; adding the scroll offset gives content coords.
//    func handleExternalDrop(payload: String, dropLocation: CGPoint) -> Bool {
//        guard let id = UUID(uuidString: payload),
//              store.unscheduled.contains(where: { $0.id == id }) else { return false }
//
//        // Subtract the same top inset the task blocks use so the drop lands where it looks.
//        let contentY  = dropLocation.y + scrollBox.y - Theme.lineInset - 1
//        let rawMins   = Int(contentY / kPPM) + kTimelineStartMinutes
//        let snapped   = snappedMinutes(rawMins)
//        let dur       = 60   // default 1 h for freshly-dropped tasks
//        let clamped   = min(max(snapped, kTimelineStartMinutes), kTimelineEndMinutes - dur)
//        let startHour = minutesToHours(clamped)
//        let endHour   = startHour + minutesToHours(dur)
//
//        guard !store.overlapsBlocker(start: startHour, end: endHour, on: selectedDate, excluding: UUID()) else { return false }
//        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
//            store.schedule(unscheduledID: id, startHour: startHour, on: selectedDate)
//        }
//        return true
//    }
    
    func handleExternalDrop(payload: String, dropLocation: CGPoint) -> Bool {
        endExternalDrag()
        guard let id = UUID(uuidString: payload),
              let u = store.unscheduled.first(where: { $0.id == id }) else { return false }

        let contentY = dropLocation.y + scrollBox.y - Theme.lineInset - 1
        let rawMins  = Int(contentY / kPPM) + kTimelineStartMinutes
        let snapped  = snappedMinutes(rawMins)
        let dur      = u.durationMinutes   // the task's real length
        let clamped  = min(max(snapped, kTimelineStartMinutes), kTimelineEndMinutes - dur)

        // Same availability rule as dragging a tile: ask the planner.   //NEW not in zip.
        let probe = TimelineTask(title: u.title,
                                 startHour: minutesToHours(clamped),
                                 endHour: minutesToHours(clamped + dur),
                                 color: u.color, isPinned: true,
                                 date: calendar.startOfDay(for: selectedDate))
        let plans = planner.plans(for: probe, on: selectedDate, among: store.tasks, now: Date())
        guard let placement = resolvePlacement(plans: plans, proposedStart: clamped, duration: dur),
              placement.kind == .whole, let seg = placement.segments.first else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return false
        }

        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            store.schedule(unscheduledID: id, startHour: minutesToHours(seg.start), on: selectedDate)
        }
        return true
    }
}
