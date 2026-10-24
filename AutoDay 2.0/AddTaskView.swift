//
//  AddTaskView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 20/10/26.
//
//  One form for both "Add Task" and "Edit Task".
//  Pass `editing:` to prefill it from an existing task.

import SwiftUI

// MARK: - Draft model

enum TaskImportance: String, CaseIterable, Identifiable {
    case low, medium, high
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

enum TaskRepeat: String, CaseIterable, Identifiable {
    case never, daily, weekdays, weekends, weekly, monthly
    var id: Self { self }
    var title: String { rawValue.capitalized }
}

/// What the form hands back on save. Map this to your scheduler's task model.
struct NewTaskDraft {
    var title: String = ""
    var durationMinutes: Int = 0                 // 0 = not set yet
    var importance: TaskImportance = .medium
    var isFixed: Bool = false
    var startDate: Date = NewTaskDraft.nextHour()
    var hasDeadline: Bool = false
    var deadline: Date = NewTaskDraft.tomorrowEvening()
    var isSplittable: Bool = false
    var repeatRule: TaskRepeat = .never

    private static func nextHour() -> Date {
        let cal = Calendar.current
        let next = cal.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
        return cal.date(bySetting: .minute, value: 0, of: next) ?? next
    }

    private static func tomorrowEvening() -> Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: 18, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }
}

// MARK: - Prefill from an existing task

extension NewTaskDraft {
    init(task: TimelineTask) {
        self.init()
        title           = task.title
        durationMinutes = Int((task.durationHours * 60).rounded())
        importance      = task.importance
        isFixed         = task.isFixed
        startDate       = Self.date(on: task.date, hour: task.startHour)
        hasDeadline     = task.deadline != nil
        if let d = task.deadline { deadline = d }
        isSplittable    = task.isSplittable
        repeatRule      = task.repeatRule
    }

    /// `day` at a fractional hour, e.g. 9.75 -> 09:45.
    private static func date(on day: Date, hour: Double) -> Date {
        let total = Int((hour * 60).rounded())
        return Calendar.current.date(bySettingHour: total / 60, minute: total % 60,
                                     second: 0, of: day) ?? day
    }
}

// MARK: - Add / Edit Task View

struct AddTaskView: View {

    var onSave: (NewTaskDraft) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewTaskDraft
    @State private var showDurationWheel = false
    @State private var splitTouched: Bool
    @FocusState private var titleFocused: Bool

    private let isEditing: Bool
    private var deleteAction: (() -> Void)? = nil
    @State private var confirmDelete = false
    private let primary   = Color(hex: "#7C5CD6")
    private let secondary = Color(hex: "#EDE7FB")

    /// - Parameter task: pass an existing task to open the form in edit mode, prefilled.
    init(editing task: TimelineTask? = nil, onSave: @escaping (NewTaskDraft) -> Void) {
        self.onSave = onSave
        self.isEditing = task != nil
        _draft = State(initialValue: task.map(NewTaskDraft.init(task:)) ?? NewTaskDraft())
        // When editing, never let the duration auto-toggle override the saved Splittable value.
        _splitTouched = State(initialValue: task != nil)
    }

    /// Adds a "Delete Task" button (edit mode only). Usage: `AddTaskView(editing: t) { ... }.withDelete { ... }`
    func withDelete(_ action: @escaping () -> Void) -> AddTaskView {
        var copy = self
        copy.deleteAction = action
        return copy
    }

    private var isValid: Bool {
        !draft.title.trimmingCharacters(in: .whitespaces).isEmpty && draft.durationMinutes > 0
    }

    var body: some View {
        NavigationStack {
            Form {
                taskDetailsSection
                schedulingSection
                preferencesSection
                deleteSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: "#FBFAFC").ignoresSafeArea())
            .navigationTitle(isEditing ? "Edit Task" : "Add Task")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete this task?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete Task", role: .destructive) {
                    deleteAction?()
                    dismiss()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(.primary)
                    .accessibilityLabel("Close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        var out = draft
                        out.title = out.title.trimmingCharacters(in: .whitespaces)
                        if out.isFixed { out.isSplittable = false }
                        onSave(out)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(primary)
                    .disabled(!isValid)
                    .accessibilityLabel(isEditing ? "Save changes" : "Add task")
                }
            }
            .onAppear {
                // Only pop the keyboard for a new task; editing shouldn't cover the form.
                if !isEditing { titleFocused = true }
            }
            .onChange(of: draft.durationMinutes) { _, new in
                // Auto-enable splitting at 90+ min until the user touches the toggle.
                if !splitTouched { draft.isSplittable = new >= 90 }
            }
        }
        .tint(primary)
        .presentationDragIndicator(.visible)
    }

    // MARK: Task Details

    private var taskDetailsSection: some View {
        Section("Task Details") {
            Label{
                TextField("Title", text: $draft.title)
                    .focused($titleFocused)
                    .submitLabel(.done)
            } icon: {
                Image(systemName: "textformat")
                    .foregroundStyle(primary)
                    .frame(width: 22)
            }

            HStack {
                rowLabel("Duration", "timer")
                Spacer()
                Button {
                    titleFocused = false
                    withAnimation(.snappy) { showDurationWheel.toggle() }
                } label: {
                    pill(draft.durationMinutes > 0 ? durationText(draft.durationMinutes) : "Set")
                }
                .buttonStyle(.plain)
            }

            if showDurationWheel {
                durationWheel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var durationWheel: some View {
        let hours = Binding<Int>(
            get: { draft.durationMinutes / 60 },
            set: { draft.durationMinutes = $0 * 60 + draft.durationMinutes % 60 }
        )
        let minutes = Binding<Int>(
            get: { draft.durationMinutes % 60 },
            set: { draft.durationMinutes = (draft.durationMinutes / 60) * 60 + $0 }
        )

        return HStack(spacing: 0) {
            Picker("Hours", selection: hours) {
                ForEach(0...12, id: \.self) { Text("\($0) hr").tag($0) }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)

            Picker("Minutes", selection: minutes) {
                ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) {
                    Text("\($0) min").tag($0)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxWidth: .infinity)
        }
        .frame(height: 130)
        .clipped()
    }

    // MARK: Scheduling

    private var schedulingSection: some View {
        Section("Scheduling") {
            HStack {
                rowLabel("Importance", "flag.fill", color: importanceColor)
                Spacer()
                Menu {
                    Picker("Importance", selection: $draft.importance) {
                        ForEach(TaskImportance.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    pill(draft.importance.title, chevron: true)
                }
            }

            Toggle(isOn: $draft.isFixed.animation(.snappy)) {
                rowLabel("Fixed time", "pin.fill")
            }

            if draft.isFixed {
                HStack {
                    rowLabel("Start", "play.circle")
                    Spacer()
                    DatePicker("", selection: $draft.startDate, displayedComponents: .date)
                        .labelsHidden()
                    DatePicker("", selection: $draft.startDate, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Toggle(isOn: $draft.hasDeadline.animation(.snappy)) {
                rowLabel("Deadline", "calendar.badge.exclamationmark")
            }

            if draft.hasDeadline {
                HStack {
                    rowLabel("Due", "clock.badge.exclamationmark")
                    Spacer()
                    DatePicker("", selection: $draft.deadline, displayedComponents: .date)
                        .labelsHidden()
                    DatePicker("", selection: $draft.deadline, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    // MARK: Additional Preferences

    private var preferencesSection: some View {
        Section {
            if !draft.isFixed {
                Toggle(isOn: Binding(
                    get: { draft.isSplittable },
                    set: { draft.isSplittable = $0; splitTouched = true }
                )){
                    rowLabel("Splittable", "square.split.2x1")
                }
                .transition(.opacity)
            }

            HStack {
                rowLabel("Repeat", "repeat")
                Spacer()
                Menu {
                    Picker("Repeat", selection: $draft.repeatRule) {
                        ForEach(TaskRepeat.allCases) { Text($0.title).tag($0) }
                    }
                } label: {
                    pill(draft.repeatRule.title, chevron: true)
                }
            }
        } header: {
            Text("Additional Preferences")
        } footer: {
            if !draft.isFixed {
                Text("Splittable lets the scheduler break this task into smaller chunks when no single gap fits.")
            }
        }
        .animation(.snappy, value: draft.isFixed)
    }

    // MARK: Delete (edit mode only)

    @ViewBuilder
    private var deleteSection: some View {
        if isEditing, deleteAction != nil {
            Section {
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Text("Delete Task")
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    // MARK: Helpers

    private func rowLabel(_ title: String, _ symbol: String, color: Color? = nil) -> some View{
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color ?? primary)
                .frame(width: 22)
        }
    }

    private var importanceColor: Color{
        switch draft.importance {
        case .low:
            return .gray
        case .medium:
            return .orange
        case .high:
            return .red
        }
    }

    private func pill(_ text: String, chevron: Bool = false) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 15, weight: .semibold))
            if chevron {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
        }
        .foregroundStyle(primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(secondary, in: Capsule())
    }

    private func durationText(_ minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) hr"
        default:     return "\(h) hr \(m) min"
        }
    }
}

// MARK: - Preview

#Preview {
    Color.clear.sheet(isPresented: .constant(true)) {
        AddTaskView { _ in }
    }
}
