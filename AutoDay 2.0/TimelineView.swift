//
//  TimelineView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 19/10/26.
//
//  Main screen layout

import SwiftUI
import Combine

// MARK: - Main View

struct TimelineView: View {

    // Properties used by DragTimelineView.swift are internal (not private).
    @State var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showMonthPicker = false
    @State private var pickerMonth: Date = Date()
    @State private var sheetExpanded = false
    @State private var currentTime: Date = Date()
    @State private var stripWeekID: Date?
    @State private var isSyncingStrip = false
    @State private var showAddTask = false
    @State private var snoozeTask: TimelineTask? = nil
    @State private var taskBeingEdited: TimelineTask? = nil
    
    @State var isOverTrash = false
    @State var trashFrame: CGRect = .zero      // global frame of the header pill
    
    //@State var undoItem: DeletedTask? = nil //being replaced.
    @State var undoStack: [UndoEntry] = []          //NEW not in zip.
    @State var snoozeContext: SnoozeContext? = nil  //NEW not in zip.
    @State var snoozeEffect: SnoozeEffect? = nil    //NEW not in zip.
    
    @State var slotPlans: [SlotPlan] = []
    // Manual mode: an Unscheduled row is being dragged out of the Tasks sheet.
    @State var externalDragTask: UnscheduledTask? = nil
    @State var externalPlans: [SlotPlan] = []
    @State var floatingTask: TimelineTask? = nil
    @State var dragOriginFrame: CGRect = .zero
    @State var dragTranslation: CGSize = .zero
    
    @State var celebration: Celebration? = nil //NEW not in zip.
    @State var lastCelebrationAt: Date? = nil  //NEW not in zip.
    
    @State var missedTracker = MissedTracker()                  //NEW not in zip.
    @Environment(\.scenePhase) private var scenePhase           //NEW not in zip.
    
    let planner: any SlotPlanner = EngineSlotPlanner()
    @AppStorage("isAutoMode") private var isAutoMode = true

    // ── Drag state ────────────────────────────────────────────────────────
    @State var draggedTaskId: UUID? = nil
    /// Snapped ghost position in fractional hours, set while a drag is live.
    @State var ghostHour: Double? = nil
    /// Timeline scroll offset, used to convert drop locations to content coordinates.
    @State var scrollBox = ScrollBox()
    /// Edge-hold day flipping while dragging: -1 = left edge, 1 = right edge, 0 = none.
    @State var edgeDirection = 0
    @State var edgeWork: DispatchWorkItem?
    @State var autoScrollTimer: Timer?

    @StateObject var store = TimelineStore()

    /// Start dates of every week the strip can page through (±5 years).
    private let stripWeeks: [Date] = {
        let cal = Calendar.current
        let thisWeek = cal.dateInterval(of: .weekOfYear, for: Date())?.start
            ?? cal.startOfDay(for: Date())
        return (-260...260).compactMap { cal.date(byAdding: .weekOfYear, value: $0, to: thisWeek) }
    }()

    let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var calendar: Calendar { Calendar.current }
    private var today: Date { calendar.startOfDay(for: Date()) }
    private var isToday: Bool { calendar.isDate(selectedDate, inSameDayAs: today) }

    private func weekStart(of date: Date) -> Date {
        calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    private func days(in weekStart: Date) -> [Date] {
        (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: weekStart) }
    }

    /// Programmatic scroll: marks the strip as syncing so the resulting
    /// stripWeekID change isn't mistaken for a user swipe.
    private func syncStrip(to week: Date, animated: Bool) {
        guard stripWeekID != week else { return }
        isSyncingStrip = true
        if animated {
            withAnimation(.snappy) { stripWeekID = week }
        } else {
            stripWeekID = week
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { isSyncingStrip = false }
    }

    private var dateStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 0) {
                ForEach(stripWeeks, id: \.self) { week in
                    HStack(spacing: 8) {
                        ForEach(days(in: week), id: \.self) { day in
                            DayCell(
                                day: day,
                                isToday: calendar.isDate(day, inSameDayAs: today),
                                isSelected: calendar.isDate(day, inSameDayAs: selectedDate)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                withAnimation(.spring(duration: 0.3)) { selectedDate = day }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .containerRelativeFrame(.horizontal)
                    .id(week)
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $stripWeekID)
        .frame(height: 80)   // 52 cell + 6 + 6 vertical padding, with breathing room
        .onAppear { syncStrip(to: weekStart(of: selectedDate), animated: false) }
        .onChange(of: selectedDate) { _, new in
            // Same week → strip stays put. Different week → page to it.
            syncStrip(to: weekStart(of: new), animated: true)
        }
        .onChange(of: stripWeekID) { _, newWeek in
            // User swiped the strip to another week: keep the same weekday selected.
            guard !isSyncingStrip, let newWeek else { return }
            let currentWeek = weekStart(of: selectedDate)
            guard currentWeek != newWeek else { return }
            let offset = calendar.dateComponents([.day], from: currentWeek, to: selectedDate).day ?? 0
            if let d = calendar.date(byAdding: .day, value: offset, to: newWeek) {
                selectedDate = d
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Theme.bg.ignoresSafeArea()

                VStack(spacing: 0) {
                    monthHeader
                    dateStrip
                    Divider().background(Theme.divider)
                    missedBanner                                                //NEW not in zip.
                    scheduleWarningBanner                                       // alerts 8, 9, 10
                    dayTimeline
                        .sheet(item: $snoozeTask) { task in
//                            SnoozeSheetView(
//                                taskTitle: task.title,
//                                onSelect: { option in
//                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
//                                        store.snooze(task.id, option: option)
//                                    }
//                                    snoozeTask = nil
//                                },
//                                onCancel: { snoozeTask = nil }
//                            ) //being replaced
                            SnoozeSheetView(
                                taskTitle: task.title,
                                taskStart: snoozeStartDate(for: task),          //NEW not in zip.
                                onSelect: { option in
                                    snoozeTask = nil
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {   //NEW not in zip. (waits for the sheet to dismiss)
                                        performSnooze(task, option: option)
                                    }
                                },
                                onCancel: { snoozeTask = nil }
                            )
                            .presentationDetents([.height(400)])
                        }
                }
                VStack(spacing: 8) {
                    scheduleToast                                       // alerts 1-5, 7, 12-14
//                    if let item = undoItem {
//                        undoToast(item)
//                            .transition(.move(edge: .bottom).combined(with: .opacity))
//                    } //being replaced
                    if let entry = undoStack.last {                     //NEW not in zip.
                        undoToast(entry)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    bottomSheet
                }
//                .task(id: undoItem?.task.id) {
//                    guard undoItem != nil else { return }
//                    do { try await Task.sleep(for: .seconds(5)) } catch { return }  // cancelled by a newer delete
//                    withAnimation(.easeInOut) { undoItem = nil }
//                } //being replaced
                .task(id: undoStack.last?.id) {                     //NEW not in zip.
                    guard !undoStack.isEmpty else { return }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    withAnimation(.easeInOut) { undoStack.removeAll() }
                }
            }
            // Catch-all: a drag from the Tasks sheet released anywhere except the timeline
            // (which has its own destination) ends the placement mode. Returning false = not accepted.
            .dropDestination(for: String.self) { _, _ in endExternalDrag(); return false }
            .toolbar(.hidden, for: .navigationBar)
            .onReceive(timer) { _ in currentTime = Date(); checkMissed(scroll: false) } //NEW not in zip.
            .overlay { floatingLayer }
            .overlay { celebrationLayer } //NEW not in zip.
            .overlay { snoozeLayer } //NEW not in zip.
            .scheduleDialogs(store)                                  // alerts 6, 11
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { checkMissed(scroll: true) }
            }//NEW not in zip.
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { checkMissed(scroll: true) }
                }
            }//NEW not in zip.
            .onChange(of: selectedDate) { _, _ in refreshSlotPlans() }
            .onChange(of: activePlacement?.id) { _, new in activePlacementChanged(new) }
            .sheet(isPresented: $showAddTask) {
                AddTaskView { draft in
                    withAnimation(.snappy) { store.add(draft) }
                }
            }
            .sheet(item: $taskBeingEdited) { task in
                AddTaskView(editing: task) { draft in
                    withAnimation(.snappy) { store.update(task.id, from: draft) }
                }
                .withDelete { deleteTask(task) }
            }
        }
    }

    // MARK: - Manual mode: drag from the Tasks sheet

    /// Closes the sheet and shows where the task can go. Runs when the row is lifted.
    func beginExternalDrag(_ u: UnscheduledTask) {
        guard !isAutoMode else { return }
        let probe = TimelineTask(title: u.title,
                                 startHour: 9,
                                 endHour: 9 + Double(u.durationMinutes) / 60,
                                 color: u.color, isPinned: true,
                                 date: calendar.startOfDay(for: selectedDate))
        DispatchQueue.main.async {
            externalDragTask = u
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                externalPlans = planner.plans(for: probe, on: selectedDate, among: store.tasks, now: Date())
            }
        }
        // Slightly later, so the system drag has fully started before the row leaves the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard externalDragTask?.id == u.id else { return }
            withAnimation(.spring(duration: 0.4)) { sheetExpanded = false }
        }
    }

    /// Drop landed, was refused, or the drag ended elsewhere.
    func endExternalDrag() {
        guard externalDragTask != nil else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            externalDragTask = nil
            externalPlans = []
        }
    }

    // MARK: Month Header

    private var monthTitle: String {
        let f = DateFormatter()
        let sameYear = calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
        return f.string(from: selectedDate)
    }

    private var monthHeader: some View {
        HStack {
            // Left pill: month, opens the month picker
            Button {
                pickerMonth = selectedDate
                showMonthPicker = true
            } label: {
                HStack(spacing: 6) {
                    Text(monthTitle)
                        .font(.system(size: 17, weight: .semibold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.labelGray)
                }
                .foregroundStyle(Color.primary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .modifier(GlassCapsule())
            }
            .buttonStyle(.plain)

            Spacer()

            // Right pill: mode switch + add task
            HStack(spacing: 16) {
                Button {
                    withAnimation(.snappy) { isAutoMode.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isAutoMode ? "wand.and.stars" : "hand.tap.fill")
                        Text(isAutoMode ? "Auto" : "Manual")
                    }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                }

                Button { showAddTask = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                }
            }
            .buttonStyle(.plain)
            .opacity(draggedTaskId != nil ? 0 : 1)                 // fade the controls, keep the pill
            .allowsHitTesting(draggedTaskId == nil)
            .overlay { trashLabel.opacity(draggedTaskId != nil ? 1 : 0) }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .background(Capsule().fill(Theme.rescheduleRed.opacity(isOverTrash ? 0.22 : 0)))
            .modifier(GlassCapsule())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { trashFrame = $0 }
            .scaleEffect(isOverTrash ? 1.06 : 1)
            .animation(.snappy(duration: 0.2), value: draggedTaskId != nil)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOverTrash)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .sheet(isPresented: $showMonthPicker) {
            MonthPickerView(pickerMonth: $pickerMonth) {
                let comps = calendar.dateComponents([.year, .month], from: pickerMonth)
                if let first = calendar.date(from: comps) {
                    selectedDate = first
                }
                showMonthPicker = false
            }
            .presentationDetents([.height(370)])
        }
    }

    // MARK: Day Timeline

    private var dayTimeline: some View {
        let hours  = Array(kTimelineStart...kTimelineEnd)
        let nowFrac = nowFractionInDay()
        let totalH = CGFloat(hours.count) * Theme.hourHeight

        return GeometryReader { outerGeo in
            let tlFrame = outerGeo.frame(in: .global)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    ZStack(alignment: .topLeading) {

                        // ── Scroll-offset tracker ──────────────────────────
                        // Measured against the ScrollView's own (stationary) coordinate space.
                        GeometryReader { inner in
                            Color.clear
                                .preference(
                                    key: ScrollOffsetKey.self,
                                    value: -inner.frame(in: .named(kTimelineSpace)).minY
                                )
                        }
                        .frame(height: 0)

                        // ── Hour grid ──────────────────────────────────────
                        VStack(spacing: 0) {
                            ForEach(hours, id: \.self) { h in HourRow(hour: h) }
                        }

                        // ── Vertical line + now indicator ──────────────────
                        GeometryReader { _ in
                            let lineX = Theme.labelWidth + 12
                            let nowY  = CGFloat(nowFrac - Double(kTimelineStart)) * Theme.hourHeight + Theme.lineInset
                            let clampedNowY = min(max(nowY, 0), totalH)

                            Rectangle()
                                .fill(isToday ? Theme.primary : Theme.secondary)
                                .frame(width: 2, height: isToday ? clampedNowY : totalH)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .offset(x: lineX - 1, y: 0)

                            if isToday {
                                Rectangle()
                                    .fill(Theme.secondary)
                                    .frame(width: 2, height: max(0, totalH - clampedNowY))
                                    .offset(x: lineX - 1, y: clampedNowY)

                                Circle()
                                    .fill(Theme.primary)
                                    .frame(width: 12, height: 12)
                                    .offset(x: lineX - 6, y: clampedNowY - 6)
                                    .id("nowDot")

                                Text(currentTime, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute())
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Theme.primary, in: Capsule())
                                    .offset(x: 2, y: clampedNowY - 10)
                                    .id("nowChip")
                            }
                        }
                        //.overlay(alignment: .top) { noSlotCapsule }
                        .frame(height: totalH)

                        // ── Slot placeholders (shown while dragging) ──────
                        if let t = floatingTask {
                            SlotPlaceholdersLayer(color: t.color, plans: slotPlans, active: activePlacement)
                                .allowsHitTesting(false)
                        } else if let u = externalDragTask {
                            SlotPlaceholdersLayer(color: u.color, plans: externalPlans, active: nil)
                                .allowsHitTesting(false)
                        }

                        // ── Task blocks ────────────────────────────────────
                        ForEach(visibleTasks) { task in
                            DraggableTaskBlock(
                                task: task,
                                isBeingDragged: draggedTaskId == task.id,
                                isOffDay: !calendar.isDate(task.date, inSameDayAs: selectedDate),
                                onDragChanged: { dy, loc in
                                    handleDragChanged(task: task, deltaY: dy, location: loc, frame: tlFrame)
                                },
                                onDragEnded: { dy in handleDragEnded(task: task, deltaY: dy) },
                                onSwipeDone: { completeTask(task, tileFrame: tileFrame(for: task, in: tlFrame)) },
                                onSwipeSnooze: {
                                    snoozeContext = makeSnoozeContext(for: task, in: tlFrame)
                                    snoozeTask = task
                                }, //NEW not in zip.
                                onEdit: { taskBeingEdited = task },
                                onDelete: { deleteTask(task) },
                                isDimmed: draggedTaskId != nil && draggedTaskId != task.id,
//                                isSettling: floatingTask?.id == task.id && draggedTaskId == nil
                                isSettling: floatingTask?.id == task.id && draggedTaskId == nil,
                                isMissed: isMissedDisplayed(task),                          //NEW not in zip.
                                isShaking: missedTracker.shaking.contains(task.id)          //NEW not in zip.
                            )
                        }
                    }
                    .padding(.bottom, 100)
                    .background(ScrollViewFinder { scrollBox.sv = $0 })
                }
                .coordinateSpace(name: kTimelineSpace)
                // ── Day-swipe: horizontal only; ignored while a task is held, or when the
                //    swipe starts on a task tile (tile swipes are done / snooze) ──
                .gesture(
                    DragGesture(minimumDistance: 40)
                        .onEnded { val in
                            guard draggedTaskId == nil else { return }
                            guard !isOnTaskTile(val.startLocation, width: outerGeo.size.width) else { return }
                            guard abs(val.translation.width) > abs(val.translation.height) else { return }
                            if val.translation.width < -40 { moveDay(by: 1) }
                            else if val.translation.width > 40 { moveDay(by: -1) }
                        }
                )
                // ── Drop destination for bottom-sheet unscheduled rows ─────
                // Payload: the unscheduled task's UUID string.
                .dropDestination(for: String.self) { items, location in
                    guard let payload = items.first else { return false }
                    return handleExternalDrop(payload: payload, dropLocation: location)
                }
                .onPreferenceChange(ScrollOffsetKey.self) { scrollBox.y = $0 }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        proxy.scrollTo("nowDot", anchor: .center)
                    }
                }
            }
        }.overlay(alignment: .top) { timelineTopOverlay }            //NEW not in zip.
    }

    // MARK: - Day helpers

    private func nowFractionInDay() -> Double {
        let comps = calendar.dateComponents([.hour, .minute], from: currentTime)
        return Double(comps.hour ?? 0) + Double(comps.minute ?? 0) / 60.0
    }

    /// Used by the day-swipe here and by the edge-hold flip in DragTimelineView.swift.
    func moveDay(by offset: Int) {
        withAnimation(.easeInOut(duration: 0.25)) {
            if let d = calendar.date(byAdding: .day, value: offset, to: selectedDate) {
                selectedDate = d
            }
        }
    }

    /// True if a touch that began at `p` (ScrollView-local coordinates) landed on a task tile.
    private func isOnTaskTile(_ p: CGPoint, width: CGFloat) -> Bool {
        guard p.x >= Theme.labelWidth + 24, p.x <= width - 16 else { return false }
        let contentY = p.y + scrollBox.currentY
        return visibleTasks.contains { t in
            let top = topOffsetForHour(t.startHour)
            let h   = max(CGFloat(t.durationHours) * Theme.hourHeight - 2, 32)
            return contentY >= top && contentY <= top + h
        }
    }
    
    // MARK: Helpers
    
    private var trashLabel: some View {
        HStack(spacing: 6) {
            Image(systemName: isOverTrash ? "trash.fill" : "trash")
            Text("Delete")
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(Theme.rescheduleText)
        .accessibilityHidden(true)      // VoiceOver uses the Delete action instead
    }
    
    //BEING REPLACED. The new undoToast(_ entry:) is in the new file.
    
//    private func undoToast(_ item: DeletedTask) -> some View {
//        HStack(spacing: 12) {
//            Text("“\(item.task.title)” deleted")
//                .font(.subheadline)
//                .lineLimit(1)
//            Spacer(minLength: 8)
//            Button("Undo") { undoDelete() }
//                .font(.subheadline.weight(.semibold))
//                .foregroundStyle(Theme.primary)
//                .frame(minWidth: 44, minHeight: 44)
//        }
//        .padding(.horizontal, 16)
//        .frame(height: 48)
//        .modifier(GlassCapsule())
//        .padding(.horizontal, 16)
//    }

    // MARK: Bottom Sheet

    private var bottomSheet: some View {
        VStack(spacing: 0) {
            // Drag handle
            Capsule()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 36, height: 4)
                .padding(.top, 8)
                .padding(.bottom, 6)

            // Header
            HStack(alignment: .center, spacing: 6) {
                Text("Tasks")
                    .font(.system(size: 20, weight: .bold))
                Text("\(store.tasks.count + store.unscheduled.count + store.reschedule.count)")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.labelGray)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.spring(duration: 0.4)) { sheetExpanded.toggle() }
            }

            if sheetExpanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        sectionHeader("Needs rescheduling",
                                      count: store.reschedule.count,
                                      chipColor: Theme.rescheduleRed)
                        ForEach(store.reschedule) { t in RescheduleTaskRow(task: t) }

                        Divider().padding(.vertical, 2)

                        sectionHeader("Unscheduled",
                                      count: store.unscheduled.count,
                                      chipColor: Theme.primary)
                        ForEach(store.unscheduled) { t in
                            UnscheduledTaskRow(task: t, onDragStart: { beginExternalDrag(t) })
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 32)
                }
                .frame(maxHeight: 360)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .modifier(SheetGlass())
    }

    @ViewBuilder
    private func sectionHeader(_ title: String, count: Int, chipColor: Color) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.labelGray)
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(chipColor, in: Capsule())
        }
    }
}

// MARK: - Preview

#Preview {
    TimelineView()
}
