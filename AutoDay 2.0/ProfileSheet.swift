//
//  ProfileSheet.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 05/11/26.
//
//
//  Profile sheet, styled like the Add Task form: Form sections, purple icons, lavender pills.
//  Opens on Preferences, with an App Settings screen pushed from the bottom.
//  Values live in UserDefaults through @AppStorage, so any view can read them live.

import SwiftUI
import UIKit

// MARK: - Keys and defaults

enum ProfileKeys {
    static let name          = "profileName"
    static let dayStart      = "profileDayStartHour"     // whole hours, 0...23
    static let dayEnd        = "profileDayEndHour"
    static let capacityHours = "profileCapacityHours"
    static let defaultAuto   = "profileDefaultAuto"
    static let appearance    = "appAppearance"           // 0 system, 1 light, 2 dark
}

enum ProfileDefaults {
    static let dayStart = 7                 // same range the timeline had before
    static let dayEnd   = 23
    static let minWindow = 6                // shortest allowed day, in hours
    static let capacityHours = 8.0

    static func initials(from name: String) -> String {
        name.split(separator: " ").prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
    }

    /// Call once at launch: starts the app in the user's default mode.
    static func applyLaunchMode() {
        let d = UserDefaults.standard
        if let auto = d.object(forKey: ProfileKeys.defaultAuto) as? Bool {
            d.set(auto, forKey: "isAutoMode")
        }
    }

    static func colorScheme(_ value: Int) -> ColorScheme? {
        switch value { case 1: return .light; case 2: return .dark; default: return nil }
    }
}

// MARK: - Shared look (same as AddTaskView)

fileprivate let profilePrimary   = Color(hex: "#7C5CD6")
fileprivate let profileSecondary = Color(hex: "#EDE7FB")

fileprivate func profileRowLabel(_ title: String, _ symbol: String) -> some View {
    Label {
        Text(title)
    } icon: {
        Image(systemName: symbol)
            .foregroundStyle(profilePrimary)
            .frame(width: 22)
    }
}

fileprivate func profilePill(_ text: String, chevron: Bool = false) -> some View {
    HStack(spacing: 6) {
        Text(text)
            .font(.system(size: 15, weight: .semibold))
        if chevron {
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold))
        }
    }
    .foregroundStyle(profilePrimary)
    .padding(.horizontal, 14)
    .padding(.vertical, 7)
    .background(profileSecondary, in: Capsule())
}

// MARK: - Profile sheet (Preferences)

struct ProfileSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// Earliest start / latest end (whole hours) of tasks from today onwards.
    /// The day window can't shrink past them.
    var earliestHour: Int? = nil
    var latestHour: Int? = nil

    @AppStorage(ProfileKeys.name)          private var name = ""
    @AppStorage(ProfileKeys.dayStart)      private var dayStart = ProfileDefaults.dayStart
    @AppStorage(ProfileKeys.dayEnd)        private var dayEnd = ProfileDefaults.dayEnd
    @AppStorage(ProfileKeys.capacityHours) private var capacityHours = ProfileDefaults.capacityHours
    @AppStorage(ProfileKeys.defaultAuto)   private var defaultAuto = true

    private enum Wheel { case start, end }
    @State private var openWheel: Wheel? = nil

    private var windowHours: Double { Double(max(dayEnd - dayStart, 1)) }

    // The wheels only offer values that keep every upcoming task inside the day.
    private var startRange: ClosedRange<Int> {
        let hi = max(dayStart, min(dayEnd - ProfileDefaults.minWindow, earliestHour ?? 23))
        return 0...hi
    }
    private var endRange: ClosedRange<Int> {
        let lo = min(dayEnd, max(dayStart + ProfileDefaults.minWindow, latestHour ?? 0))
        return lo...23
    }

    private var capacityOptions: [Double] {
        Array(stride(from: 1.0, through: max(windowHours, 1), by: 0.5))
    }

    private var windowFooter: String {
        var s = "The timeline shows only this window."
        if let e = earliestHour, e == dayStart {
            s += " A task starts at \(label(e)), so the start can't move later."
        }
        if let l = latestHour, l == dayEnd {
            s += " A task ends at \(label(l)), so the end can't move earlier."
        }
        return s
    }

    var body: some View {
        NavigationStack {
            Form {
                profileSection
                daySection
                planningSection
                settingsSection
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: "#FBFAFC").ignoresSafeArea())
            .navigationTitle("Preferences")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: {
                        Image(systemName: "checkmark").fontWeight(.bold)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(profilePrimary)
                    .accessibilityLabel("Done")
                }
            }
            // Keep capacity inside the day when the window shrinks.
            .onChange(of: dayStart) { _, _ in capacityHours = min(capacityHours, windowHours) }
            .onChange(of: dayEnd)   { _, _ in capacityHours = min(capacityHours, windowHours) }
        }
        .tint(profilePrimary)
        .presentationDragIndicator(.visible)
    }

    // MARK: Profile

    private var profileSection: some View {
        Section("Profile") {
            Label {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .submitLabel(.done)
            } icon: {
                Image(systemName: "person.fill")
                    .foregroundStyle(profilePrimary)
                    .frame(width: 22)
            }
        }
    }

    // MARK: Your day

    private var daySection: some View {
        Section {
            HStack {
                profileRowLabel("Day starts", "sunrise.fill")
                Spacer()
                Button {
                    withAnimation(.snappy) { openWheel = (openWheel == .start ? nil : .start) }
                } label: {
                    profilePill(label(dayStart))
                }
                .buttonStyle(.plain)
            }
            if openWheel == .start {
                hourWheel(selection: $dayStart, range: startRange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            HStack {
                profileRowLabel("Day ends", "moon.stars.fill")
                Spacer()
                Button {
                    withAnimation(.snappy) { openWheel = (openWheel == .end ? nil : .end) }
                } label: {
                    profilePill(label(dayEnd))
                }
                .buttonStyle(.plain)
            }
            if openWheel == .end {
                hourWheel(selection: $dayEnd, range: endRange)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            Text("Your Day")
        } footer: {
            Text(windowFooter)
        }
    }

    private func hourWheel(selection: Binding<Int>, range: ClosedRange<Int>) -> some View {
        Picker("Hour", selection: selection) {
            ForEach(Array(range), id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.wheel)
        .frame(height: 130)
        .clipped()
    }

    // MARK: Planning

    private var planningSection: some View {
        Section {
            HStack {
                profileRowLabel("Daily capacity", "hourglass")
                Spacer()
                Menu {
                    Picker("Daily capacity", selection: $capacityHours) {
                        ForEach(capacityOptions, id: \.self) { Text(hoursText($0)).tag($0) }
                    }
                } label: {
                    profilePill(hoursText(capacityHours), chevron: true)
                }
            }

            HStack {
                profileRowLabel("Mode on launch", "wand.and.stars")
                Spacer()
                Menu {
                    Picker("Mode on launch", selection: $defaultAuto) {
                        Text("Auto").tag(true)
                        Text("Manual").tag(false)
                    }
                } label: {
                    profilePill(defaultAuto ? "Auto" : "Manual", chevron: true)
                }
            }
        } header: {
            Text("Planning")
        } footer: {
            Text("Capacity is the task time that counts as a full day in the week view. The Auto / Manual button still switches mode any time.")
        }
    }

    // MARK: App settings

    private var settingsSection: some View {
        Section {
            NavigationLink {
                AppSettingsView()
            } label: {
                profileRowLabel("App Settings", "gearshape")
            }
        }
    }

    // MARK: Helpers

    private func label(_ hour: Int) -> String { String(format: "%02d:00", hour) }

    private func hoursText(_ h: Double) -> String {
        let m = Int((h * 60).rounded())
        let hh = m / 60, mm = m % 60
        if hh == 0 { return "\(mm) min" }
        return mm == 0 ? "\(hh) h" : "\(hh) h \(mm) min"
    }
}

// MARK: - App Settings

struct AppSettingsView: View {
    @AppStorage(ProfileKeys.appearance) private var appearance = 0

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
    }

    private var appearanceTitle: String {
        switch appearance { case 1: return "Light"; case 2: return "Dark"; default: return "System" }
    }

    var body: some View {
        Form {
            Section("Appearance") {
                HStack {
                    profileRowLabel("Theme", "circle.lefthalf.filled")
                    Spacer()
                    Menu {
                        Picker("Theme", selection: $appearance) {
                            Text("System").tag(0)
                            Text("Light").tag(1)
                            Text("Dark").tag(2)
                        }
                    } label: {
                        profilePill(appearanceTitle, chevron: true)
                    }
                }
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    HStack {
                        profileRowLabel("Notification settings", "bell")
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Opens AutoDay's notification settings in iOS.")
            }

            Section("About") {
                HStack {
                    profileRowLabel("Version", "info.circle")
                    Spacer()
                    Text(version).foregroundStyle(.secondary)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(hex: "#FBFAFC").ignoresSafeArea())
        .navigationTitle("App Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ProfileSheet()
}
