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

enum TimelineViewMode: CaseIterable {
    case day, week
    var title: String { self == .day ? "Day" : "Week" }
    var symbol: String { self == .day ? "rectangle.grid.1x3" : "rectangle.split.3x1" }
}

struct TimelineView: View {

    // Properties used by DragTimelineView.swift are internal (not private).
    @State var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    @State private var showMonthPicker = false
    @State private var pickerMonth: Date = Date()
    @State private var sheetExpanded = false
    @State private var currentTime: Date = Date()
    @State private var stripWeekID: Date?
    @State private var isSyncingStrip = false
    @State private var stripWidth: CGFloat = 0          // detects rotation of the date strip
    @State private var showAddTask = false
    @State private var snoozeTask: TimelineTask? = nil
    @State private var taskBeingEdited: TimelineTask? = nil
    
    @State var isOverTrash = false
    @State var trashFrame: CGRect = .zero      // global frame of the header pill
    
    //@State var undoItem: DeletedTask? = nil //being replaced.
    @State var undoStack: [UndoEntry] = []          //NEW not in zip.
    @State var taskPendingDelete: TimelineTask? = nil   //NEW not in zip. ("Are you sure?" alert)
    @State var snoozeContext: SnoozeContext? = nil  //NEW not in zip.
    @State var snoozeEffect: SnoozeEffect? = nil    //NEW not in zip.
    
    @State var slotPlans: [SlotPlan] = []
    // Manual mode: an Unscheduled row is being dragged out of the Tasks sheet.
    @State var pendingSplit: PendingSplit? = nil
    @State var externalDragTask: UnscheduledTask? = nil
    @State var externalPlans: [SlotPlan] = []
    @State var externalActive: SlotPlan? = nil                              //NEW not in zip.
    //@State var noSlotMessage: String? = nil
    @State var floatingTask: TimelineTask? = nil
    @State var dragOriginFrame: CGRect = .zero
    @State var dragTranslation: CGSize = .zero
    
    @State var celebration: Celebration? = nil //NEW not in zip.
    @State var lastCelebrationAt: Date? = nil  //NEW not in zip.
    
    @State var missedTracker = MissedTracker()                  //NEW not in zip.
    
    @State private var viewMode: TimelineViewMode = .day
    @State private var weekShown = false
    @State private var showProfile = false
    @AppStorage(ProfileKeys.name) private var profileName = ""
    
    @State private var externalDragEndedAt = Date.distantPast               //NEW not in zip.
    @Environment(\.scenePhase) private var scenePhase           //NEW not in zip.
    
    let planner: any SlotPlanner = EngineSlotPlanner()
    @AppStorage("isAutoMode") private var isAutoMode = true
    @AppStorage(ProfileKeys.dayStart) private var dayStart = ProfileDefaults.dayStart
    @AppStorage(ProfileKeys.dayEnd)   private var dayEnd = ProfileDefaults.dayEnd
    

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
    
    private var taskBounds: (earliest: Int?, latest: Int?) {
        let upcoming = store.tasks.filter { $0.date >= today }
        return (upcoming.map { Int(floor($0.startHour)) }.min(),
                upcoming.map { Int(ceil($0.endHour)) }.max())
    }
    
    /// Share of today's tiles marked done (drives the avatar ring).
    private var todayProgress: Double {
        let t = store.tasks.filter { calendar.isDate($0.date, inSameDayAs: today) }
        guard !t.isEmpty else { return 0 }
        return Double(t.filter(\.isDone).count) / Double(t.count)
    }

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

    /// Rotation changes the strip's page width and leaves a stale scroll offset (it can land on the
    /// next week). Drop the position and set it again so it re-anchors to the selected week.
    private func reanchorStrip() {
        let week = weekStart(of: selectedDate)
        isSyncingStrip = true
        stripWeekID = nil
        DispatchQueue.main.async { stripWeekID = week }
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
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { w in
            defer { stripWidth = w }
            guard stripWidth != 0, abs(w - stripWidth) > 1 else { return }   // ignore the first layout
            reanchorStrip()
        }
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
                    headerBar          // was monthHeader
                    dateStrip
                    titleLine
                    Divider().background(Theme.divider)
                    missedBanner                                                //NEW not in zip.
                    scheduleWarningBanner                                       // alerts 8, 9, 10
                    dayTimeline
                        .id(dayStart * 100 + dayEnd)
                        .sheet(item: $snoozeTask) { task in
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
                }.alert("Split this task?",
                        isPresented: Binding(get: { pendingSplit != nil }, set: { _ in }),
                        presenting: pendingSplit) { p in
                     Button("Split") { confirmSplit(p) }
                     Button("Cancel", role: .cancel) { cancelSplit(p) }
                 } message: { p in
                     Text("“\(p.task.title)” won't fit in one gap. It will be split into \(p.plan.segments.count) parts: "
                          + p.plan.segments.map { "\(clock($0.start))–\(clock($0.end))" }.joined(separator: ", ") + ".")
                 }
                VStack(spacing: 8) {
                    addTaskButton                                       //NEW not in zip. (floating, bottom-right)
                    scheduleToast
                    if let entry = undoStack.last {                     //NEW not in zip.
                        undoToast(entry)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                    // Tasks sheet: hidden in Auto mode and while a tile is being dragged.
                    Group {
                        if !isAutoMode && draggedTaskId == nil {
                            bottomSheet
                                .offset(y: externalDragTask != nil ? 800 : 0)               //NEW not in zip.
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                    .animation(.spring(duration: 0.3), value: isAutoMode)
                    .animation(.spring(duration: 0.3), value: draggedTaskId == nil)
                    .animation(.spring(duration: 0.3), value: externalDragTask != nil)      //NEW not in zip.
                }
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
            .overlay {
                ZStack {
                    if weekShown {
                        WeekView(store: store,
                                 selectedDate: $selectedDate,
                                 viewMode: $viewMode,
                                 isMissed: { isMissedDisplayed($0) })
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: weekShown)
            }
            .onChange(of: viewMode) { _, mode in
                if mode == .week {
                    OrientationLock.lock(.landscape)
                    weekShown = true
                } else {
                    OrientationLock.lock(.portrait)
                    // Let the rotation finish before the day view is revealed again.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if viewMode == .day {
                            weekShown = false
                            reanchorStrip()          // portrait again: show the selected date's week
                        }
                    }
                }
            }
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
            .onChange(of: draggedTaskId) { _, new in if new != nil { sheetExpanded = false } }   //NEW not in zip.
            .onChange(of: store.focusDate) { _, d in                                             //NEW not in zip. (Undo jumps back to the task's day)
                guard let d else { return }
                withAnimation(.easeInOut(duration: 0.25)) { selectedDate = d }
                store.focusDate = nil
            }
            .sheet(isPresented: $showProfile) {
                ProfileSheet(earliestHour: taskBounds.earliest, latestHour: taskBounds.latest)
            }
            .sheet(isPresented: $showAddTask) {
                AddTaskView { draft in
                    withAnimation(.snappy) { store.add(draft) }
                }
            }
            .sheet(item: $taskBeingEdited) { task in
                AddTaskView(editing: task) { draft in
                    withAnimation(.snappy) { store.update(task.id, from: draft) }
                }
                .withDelete {
                    // Close the edit sheet first so the confirmation alert can present.   //NEW not in zip.
                    taskBeingEdited = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { deleteTask(task) }
                }
            }
            // "Are you sure?" before any delete (trash drop, tile delete, edit sheet).   //NEW not in zip.
            .alert("Are you sure?",
                   isPresented: Binding(get: { taskPendingDelete != nil },
                                        set: { if !$0 { taskPendingDelete = nil } }),
                   presenting: taskPendingDelete) { task in
                Button("Delete", role: .destructive) { performDelete(task) }
                Button("Cancel", role: .cancel) {}
            } message: { task in
                Text("“\(task.title)” will be deleted.")
            }
        }
    }

    // MARK: - Manual mode: drag from the Tasks sheet

    /// Closes the sheet and shows where the task can go. Runs when the row is lifted.
    func beginExternalDrag(_ u: UnscheduledTask) {
        guard !isAutoMode else { return }
        guard Date().timeIntervalSince(externalDragEndedAt) > 1.0 else { return }   //NEW not in zip.
        let probe = TimelineTask(title: u.title,
                                 startHour: 9,
                                 endHour: 9 + Double(u.durationMinutes) / 60,
                                 color: u.color, isPinned: true,
                                 date: calendar.startOfDay(for: selectedDate),
                                 isSplittable: u.isSplittable,
                                 taskID: u.id)

        DispatchQueue.main.async {
            guard Date().timeIntervalSince(externalDragEndedAt) > 1.0,
                  store.draggableTask(u.id) != nil else { return }
            externalDragTask = u

            let others = store.tasks.filter { $0.taskID != u.id }
            let plans  = planner.plans(for: probe, on: selectedDate, among: others, now: Date())

            let gaps = (planner as? EngineSlotPlanner)?
                .freeGaps(on: selectedDate, excluding: probe.id, among: others, now: Date()) ?? []
            print("DIAG", u.title, "dur:", u.durationMinutes, "day:", selectedDate,
                  "plans:", plans.count,
                  "gaps:", gaps.map { "\(clock($0.start))-\(clock($0.end))" })

            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                externalPlans = plans
            }
        }
    }
    
    /// Drop landed, was refused, or the drag ended elsewhere.
    func endExternalDrag() {
        guard externalDragTask != nil else { return }
        externalDragEndedAt = Date()                                            //NEW not in zip.
        stopAutoScroll()                                                    //NEW not in zip.
        withAnimation(.easeOut(duration: 0.15)) {
            externalDragTask = nil
            externalPlans = []
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {             //NEW not in zip.
            withAnimation(.spring(duration: 0.4)) { sheetExpanded = false }
        }
    }

    // MARK: Month Header

//    private var monthTitle: String {
//        let f = DateFormatter()
//        let sameYear = calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .year)
//        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
//        return f.string(from: selectedDate)
//    }
//
//    private var monthHeader: some View {
//        HStack {
//            // Left pill: month, opens the month picker
//            Button {
//                pickerMonth = selectedDate
//                showMonthPicker = true
//            } label: {
//                HStack(spacing: 6) {
//                    Text(monthTitle)
//                        .font(.system(size: 17, weight: .semibold))
//                    Image(systemName: "chevron.down")
//                        .font(.system(size: 12, weight: .bold))
//                        .foregroundStyle(Theme.labelGray)
//                }
//                .foregroundStyle(Color.primary)
//                .padding(.horizontal, 16)
//                .frame(height: 44)
//                .modifier(GlassCapsule())
//            }
//            .buttonStyle(.plain)
//
//            Spacer()
//
//            // Right pill: mode switch (add task is the floating button now)   //NEW not in zip.
//            HStack(spacing: 16) {
//                Button {
//                    withAnimation(.snappy) { isAutoMode.toggle() }
//                } label: {
//                    HStack(spacing: 5) {
//                        Image(systemName: isAutoMode ? "wand.and.stars" : "hand.tap.fill")
//                        Text(isAutoMode ? "Auto" : "Manual")
//                    }
//                    .font(.system(size: 15, weight: .semibold))
//                    .foregroundStyle(Theme.primary)
//                }
//            }
//            .buttonStyle(.plain)
//            .opacity(draggedTaskId != nil ? 0 : 1)                 // fade the controls, keep the pill
//            .allowsHitTesting(draggedTaskId == nil)
//            .overlay { trashLabel.opacity(draggedTaskId != nil ? 1 : 0) }
//            .padding(.horizontal, 16)
//            .frame(height: 44)
//            .background(Capsule().fill(Theme.rescheduleRed.opacity(isOverTrash ? 0.22 : 0)))
//            .modifier(GlassCapsule())
//            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { trashFrame = $0 }
//            .scaleEffect(isOverTrash ? 1.06 : 1)
//            .animation(.snappy(duration: 0.2), value: draggedTaskId != nil)
//            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOverTrash)
//        }
//        .padding(.horizontal, 16)
//        .padding(.top, 8)
//        .padding(.bottom, 8)
//        .sheet(isPresented: $showMonthPicker) {
//            MonthPickerView(pickerMonth: $pickerMonth) {
//                let comps = calendar.dateComponents([.year, .month], from: pickerMonth)
//                if let first = calendar.date(from: comps) {
//                    selectedDate = first
//                }
//                showMonthPicker = false
//            }
//            .presentationDetents([.height(370)])
//        }
//    }

    private var titleText: String {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEdMMMyyyy")
        return f.string(from: selectedDate)
    }

    // MARK: Header

    private var headerBar: some View {
        let dragging = draggedTaskId != nil

        return HStack(spacing: 12) {
            // Left: Auto / Manual
            Button {
                withAnimation(.snappy) { isAutoMode.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: isAutoMode ? "wand.and.stars" : "hand.tap.fill")
                    Text(isAutoMode ? "Auto" : "Manual")
                }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.primary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .modifier(GlassCapsule())
            }
            .buttonStyle(.plain)
            .opacity(dragging ? 0 : 1)

            Spacer()

            // Right: view menu and profile, two separate buttons
            HStack(spacing: 10) {
                Menu {
                    Picker("View", selection: $viewMode) {
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

                Button { showProfile = true } label: {
                    ZStack {
                        Circle()
                            .stroke(Theme.primary.opacity(0.15), lineWidth: 3)
                            .padding(1.5)
                        Circle()
                            .trim(from: 0, to: todayProgress)
                            .stroke(Theme.doneGreen, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .padding(1.5)
                            .animation(.snappy, value: todayProgress)

                        Group {
                            if profileName.isEmpty {
                                Image(systemName: "person.fill").font(.system(size: 15, weight: .bold))
                            } else {
                                Text(ProfileDefaults.initials(from: profileName)).font(.system(size: 15, weight: .bold))
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(
                            LinearGradient(colors: [Color(hex: "#9B7FEA"), Theme.primary],
                                           startPoint: .topLeading, endPoint: .bottomTrailing),
                            in: Circle()
                        )
                        .shadow(color: Theme.primary.opacity(0.35), radius: 4, y: 2)
                    }
                    .frame(width: 44, height: 44)
                }
                .buttonStyle(AvatarPressStyle())
                .accessibilityLabel("Profile")
                .accessibilityValue("\(Int(todayProgress * 100)) percent of today's tasks done")
            }
            .buttonStyle(.plain)
            .opacity(dragging ? 0 : 1)
        }
        .allowsHitTesting(!dragging)
        // Full-width delete bar replaces the whole row while a tile is dragged
        .overlay {
            HStack(spacing: 8) {
                Image(systemName: isOverTrash ? "trash.fill" : "trash")
                Text("Drop to delete")
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Theme.rescheduleText)
            .frame(maxWidth: .infinity)
            .frame(height: 44)
            .background(Capsule().fill(Theme.rescheduleRed.opacity(isOverTrash ? 0.22 : 0)))
            .modifier(GlassCapsule())
            .scaleEffect(isOverTrash ? 1.02 : 1)
            .opacity(dragging ? 1 : 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)      // VoiceOver uses the Delete action instead
        }
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { trashFrame = $0 }
        .animation(.snappy(duration: 0.2), value: dragging)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isOverTrash)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    // MARK: Title line

    private var titleLine: some View {
        Button {
            pickerMonth = selectedDate
            showMonthPicker = true
        } label: {
            HStack(spacing: 6) {
                Text(titleText)
                    .font(.system(size: 14, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.labelGray)
            }
            .foregroundStyle(Color.primary)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
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
        let nowInRange = nowFrac >= Double(kTimelineStart) && nowFrac <= Double(kTimelineEnd)
        let totalH = CGFloat(hours.count) * Theme.hourHeight
        let lanes = taskLanes                                           //NEW not in zip.

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
                                .fill(isToday && nowInRange ? Theme.primary : Theme.secondary)
                                .frame(width: 2, height: isToday && nowInRange ? clampedNowY : totalH)
                                .frame(maxHeight: .infinity, alignment: .top)
                                .offset(x: lineX - 1, y: 0)

                            if isToday && nowInRange {
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
                        .frame(height: totalH)

                        // ── Slot placeholders (shown while dragging) ──────
                        // ── Slot placeholders (shown while dragging) ──────
                        if let t = floatingTask {
                            SlotPlaceholdersLayer(color: t.color, plans: slotPlans, active: shownPlacement)
                                .allowsHitTesting(false)
                            SplitHintLayer(tint: t.color.text, plan: shownPlacement)
                        } else if let u = externalDragTask {
                            SlotPlaceholdersLayer(color: u.color, plans: externalPlans, active: externalActive)   //NEW not in zip.
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
                                isSettling: floatingTask?.id == task.id && draggedTaskId == nil,
                                isMissed: isMissedDisplayed(task),                          //NEW not in zip.
                                isShaking: missedTracker.shaking.contains(task.id),         //NEW not in zip.
                                lane: lanes[task.id] ?? TaskLane()                          //NEW not in zip.
                            )
                        }
                    }
                    .padding(.bottom, 100)
                    .background(ScrollViewFinder { scrollBox.sv = $0 })
                }
                .coordinateSpace(name: kTimelineSpace)
                .scrollDisabled(draggedTaskId != nil)                   //NEW not in zip. (finger drag must not scroll; auto-scroll still works)
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
                // Pinch in → week view. Ignored while dragging, or when the pinch starts on a tile.
                .simultaneousGesture(
                    MagnifyGesture().onEnded { value in
                        guard draggedTaskId == nil, externalDragTask == nil else { return }
                        guard !isOnTaskTile(value.startLocation, width: outerGeo.size.width) else { return }
                        if value.magnification < 0.85 { viewMode = .week }
                    }
                )
                // ── Drop destination for bottom-sheet unscheduled rows ─────
                // Payload: the unscheduled task's UUID string.
                .onDrop(of: ExternalDropDelegate.types, delegate: ExternalDropDelegate(   //NEW not in zip.
                    onMove: { loc in updateExternalDrag(at: loc, frame: tlFrame) },         //NEW not in zip.
                    onLeave: { stopAutoScroll(); externalActive = nil },
                    onDrop: { loc in
                        stopAutoScroll()
                        guard let id = externalDragTask?.id else { endExternalDrag(); return false }
                        return handleExternalDrop(payload: id.uuidString, dropLocation: loc)
                    }
                ))
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
        let lanes = taskLanes                                           //NEW not in zip.
        let contentY = p.y + scrollBox.currentY
        return visibleTasks.contains { t in
            let g = laneGeometry(lanes[t.id] ?? TaskLane(), totalWidth: width)
            guard p.x >= g.x, p.x <= g.x + g.width else { return false }
            let top = topOffsetForHour(t.startHour)
            let h   = max(CGFloat(t.durationHours) * Theme.hourHeight - 2, 32)
            return contentY >= top && contentY <= top + h
        }
    }
    
    // MARK: Helpers

    /// Floating "add task" button, bottom-right. Sits above the toasts and the Tasks sheet.   //NEW not in zip.
    private var addTaskButton: some View {
        let visible = draggedTaskId == nil && externalDragTask == nil
        return HStack {
            if !isToday {
                Button {
                    withAnimation(.spring(duration: 0.3)) { selectedDate = today }
                } label: {
                    Text("Today")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .padding(.horizontal, 20)
                        .frame(height: 44)
                        .modifier(GlassCapsule())
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
            }
            Spacer()
            Button { showAddTask = true } label: {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(Theme.primary, in: Circle())
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add task")
        }
        .padding(.horizontal, 16)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
        .animation(.snappy(duration: 0.2), value: visible)
        .animation(.snappy, value: isToday)
    }

//    private var trashLabel: some View {
//        HStack(spacing: 6) {
//            Image(systemName: isOverTrash ? "trash.fill" : "trash")
//            Text("Delete")
//        }
//        .font(.system(size: 15, weight: .semibold))
//        .foregroundStyle(Theme.rescheduleText)
//        .accessibilityHidden(true)      // VoiceOver uses the Delete action instead
//    }

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
                Text("\(store.unscheduled.count + store.reschedule.count)")
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
                        ForEach(store.reschedule) { t in
                            RescheduleTaskRow(task: t, onDragStart: {                   //NEW not in zip.
                                if let u = store.draggableTask(t.id) { beginExternalDrag(u) }
                            })
                        }

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

/// Springy press effect for the header avatar.
struct AvatarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Preview

#Preview {
    TimelineView()
}
