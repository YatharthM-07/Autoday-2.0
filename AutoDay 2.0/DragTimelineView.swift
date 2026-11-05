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
    
    /// Overlap column for each tile on the selected day.
    var taskLanes: [UUID: TaskLane] {
        computeTaskLanes(visibleTasks.filter { calendar.isDate($0.date, inSameDayAs: selectedDate) })
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
        let g = laneGeometry(taskLanes[task.id] ?? TaskLane(), totalWidth: frame.width)
        dragOriginFrame = CGRect(
            x: frame.minX + g.x,
            y: frame.minY + topOffsetForHour(task.startHour) - scrollBox.currentY,
            width: g.width,
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
            if pendingSplit == nil {
                withAnimation(.easeOut(duration: 0.15)) { slotPlans = [] }
            }
        }

        // A long press that never turned into a drag: nothing to do.
        guard wasFloating else { return }

        // 1. Dropped on the trash.
        // Glide back to its slot, then ask "Are you sure?"; it only goes if confirmed.   //NEW not in zip.
        if overTrash {
            if dayChanged { withAnimation(.easeInOut(duration: 0.25)) { selectedDate = task.date } }
            settleFloatingTile(toStartMinutes: toMinutes(task.startHour)) {
                deleteTask(task)
            }
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
            let dropMin = toMinutes(ghostHour ?? task.startHour)
            let seg = placement.segments.min { abs($0.start - dropMin) < abs($1.start - dropMin) }
                      ?? placement.segments[0]
            pendingSplit = PendingSplit(task: task, plan: placement, date: targetDate, originDate: task.date)
            slotPlans = [placement]                       // keep only the chosen split ghosts on screen
            settleFloatingTile(toStartMinutes: seg.start) {}
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
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
            if draggedTaskId == nil && pendingSplit == nil { floatingTask = nil }
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
        if let plan = shownPlacement {
            if plan.kind == .whole, let s = plan.segments.first {
                return "\(clock(s.start)) – \(clock(s.end))"
            }
            return "Splits into \(plan.segments.count) parts"
        }
        return "\(hm(task.startHour)) – \(hm(task.endHour))"
    }

    /// Shown at the top of the timeline when the task can't go anywhere on this day.
    /// Covers both drags of tiles already on the timeline and drags out of the Tasks sheet.
    @ViewBuilder
    var noSlotCapsule: some View {
        let internalEmpty = draggedTaskId != nil && slotPlans.isEmpty && ghostHour != nil && !isOverTrash
        let externalEmpty = externalDragTask != nil && externalPlans.isEmpty

        if internalEmpty || externalEmpty {
            Label(externalEmpty
                  ? "No free slot today for “\(externalDragTask?.title ?? "task")”"
                  : "No free slot on this day",
                  systemImage: "calendar.badge.exclamationmark")
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

    /// Entry point for every delete: asks "Are you sure?" first.         //NEW not in zip.
    func deleteTask(_ task: TimelineTask) {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        taskPendingDelete = task
    }

    /// Runs after the alert is confirmed.                                //NEW not in zip.
    func performDelete(_ task: TimelineTask) {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            if let removed = store.delete(task.id) {
                pushUndo(.deleted(removed), message: "“\(task.title)” deleted")   //NEW not in zip.
            }
        }
        UIAccessibility.post(notification: .announcement,
                             argument: "\(task.title) deleted. Undo available.")
    }

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

    /// Start time (minutes from midnight) for a task dropped from the Tasks sheet at `location`
    /// (ScrollView coordinates). Centred on the finger, snapped, and kept inside the day window.
    func externalProposedStart(at location: CGPoint, duration: Int) -> Int {
        let contentY = location.y + scrollBox.currentY
        let raw = kTimelineStartMinutes + Int((contentY - Theme.lineInset - 1) / kPPM) - duration / 2
        return min(max(snappedMinutes(raw), kTimelineStartMinutes), kTimelineEndMinutes - duration)
    }

    /// Handle a drop from the bottom sheet.
    /// `dropLocation` is in the ScrollView's frame; adding the scroll offset gives content coords.
    func handleExternalDrop(payload: String, dropLocation: CGPoint) -> Bool {
        endExternalDrag()
        guard let id = UUID(uuidString: payload),
              let u = store.draggableTask(id) else { return false }          //NEW not in zip. (also Needs rescheduling)

        let dur   = u.durationMinutes
        let start = externalProposedStart(at: dropLocation, duration: dur)      //NEW not in zip.
        let probe = TimelineTask(title: u.title,
                                 startHour: 9,
                                 endHour: 9 + Double(u.durationMinutes) / 60,
                                 color: u.color, isPinned: true,
                                 date: calendar.startOfDay(for: selectedDate),
                                 isSplittable: u.isSplittable,
                                 taskID: u.id)                                //NEW not in zip.
        let plans = planner.plans(for: probe, on: selectedDate,
                                  among: store.tasks.filter { $0.taskID != u.id }, now: Date())   //NEW not in zip. (own old tile excluded)
        // Large tolerance: dropping on a busy spot snaps to the nearest free edge instead of failing.
        guard let placement = resolvePlacement(plans: plans, proposedStart: start,
                                               duration: dur, tolerance: 24 * 60) else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            store.showToast("No free slot today for “\(u.title)”. It's still in your Tasks list.",
                            icon: "exclamationmark.circle.fill")
            return false
        }

        // Split: same accept / decline alert as a timeline drag.
        if placement.kind == .split {
            pendingSplit = PendingSplit(task: probe, plan: placement,
                                        date: selectedDate, originDate: selectedDate,
                                        externalID: u.id)
            return true
        }

        guard let seg = placement.segments.first else { return false }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            _ = store.schedule(unscheduledID: id, startHour: minutesToHours(seg.start), on: selectedDate)
        }
        return true
    }
    
    var shownPlacement: SlotPlan? { activePlacement ?? pendingSplit?.plan }

    func confirmSplit(_ p: PendingSplit) {
        pendingSplit = nil
        if let id = p.externalID {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                _ = store.splitUnscheduled(id, into: p.plan.segments, on: p.date)
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            return
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            store.split(p.task.id, into: p.plan.segments, on: p.date)
            floatingTask = nil
            slotPlans = []
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    func cancelSplit(_ p: PendingSplit) {
        pendingSplit = nil
        if p.externalID != nil { return }
        if !calendar.isDate(p.originDate, inSameDayAs: selectedDate) {
            withAnimation(.easeInOut(duration: 0.25)) { selectedDate = p.originDate }
        }
        withAnimation(.easeOut(duration: 0.15)) { slotPlans = [] }
        settleFloatingTile(toStartMinutes: toMinutes(p.task.startHour)) {}
    }

    struct PendingSplit {
        let task: TimelineTask
        let plan: SlotPlan
        let date: Date
        let originDate: Date
        var externalID: UUID? = nil
    }

    /// Split cue: dashed connector between the pieces + "1/2" scissors badges.
    struct SplitHintLayer: View {
        let tint: Color
        let plan: SlotPlan?

        var body: some View {
            if let plan, plan.kind == .split {
                GeometryReader { geo in
                    let g = laneGeometry(TaskLane(), totalWidth: geo.size.width)
                    let segs = plan.segments
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(segs.indices.dropLast()), id: \.self) { i in
                            Path { p in
                                let x = g.x + 10
                                p.move(to:    CGPoint(x: x, y: topOffsetForHour(Double(segs[i].end) / 60)))
                                p.addLine(to: CGPoint(x: x, y: topOffsetForHour(Double(segs[i + 1].start) / 60)))
                            }
                            .stroke(tint.opacity(0.7), style: StrokeStyle(lineWidth: 2, dash: [4, 4]))
                        }
                        ForEach(segs.indices, id: \.self) { i in
                            Label("\(i + 1)/\(segs.count)", systemImage: "scissors")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(tint, in: Capsule())
                                .offset(x: g.x + g.width - 64,
                                        y: topOffsetForHour(Double(segs[i].start) / 60) + 4)
                        }
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
    }
}
