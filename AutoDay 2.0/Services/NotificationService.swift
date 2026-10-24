// NotificationService.swift — AutoDay · Services (OS integration)
// Section 11: every notification offers Done / Snooze / Edit.
// Snooze goes through TaskService, so it triggers an instant reschedule.

import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate {

    static let shared = NotificationService()
    private override init() { super.init() }

    private enum ID {
        static let category = "AUTODAY_TASK"
        static let done     = "AUTODAY_DONE"
        static let snooze   = "AUTODAY_SNOOZE"
        static let edit     = "AUTODAY_EDIT"
    }

    // MARK: - Setup

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let done   = UNNotificationAction(identifier: ID.done, title: "Done", options: [])
        let snooze = UNNotificationAction(identifier: ID.snooze,
                                          title: "Snooze \(SchedulerConstants.defaultSnoozeMinutes) min",
                                          options: [])
        let edit   = UNNotificationAction(identifier: ID.edit, title: "Edit", options: [.foreground])
        let category = UNNotificationCategory(identifier: ID.category,
                                              actions: [done, snooze, edit],
                                              intentIdentifiers: [],
                                              options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Scheduling

    /// Replace pending notifications with one per upcoming slot (iOS caps pending at 64).
    func sync(items: [ScheduledItem], now: Date) {
        let center = UNUserNotificationCenter.current()
        center.removeAllPendingNotificationRequests()

        let upcoming = items
            .filter { ($0.task.status == .pending || $0.task.status == .snoozed) && $0.slot.start > now }
            .sorted { $0.slot.start < $1.slot.start }
            .prefix(50)

        for item in upcoming {
            let content = UNMutableNotificationContent()
            content.title = item.task.title
            content.body = "Time to start · \(item.slot.minutes) min"
            content.sound = .default
            content.categoryIdentifier = ID.category
            content.userInfo = ["taskId": item.task.id.uuidString]

            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute],
                                                        from: item.slot.start)
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            center.add(UNNotificationRequest(identifier: item.slot.id, content: content, trigger: trigger))
        }
    }

    // MARK: - Delegate (nonisolated: hop to the main actor ourselves)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let idString = response.notification.request.content.userInfo["taskId"] as? String
        Task { @MainActor in
            NotificationService.shared.handle(action: action, taskIdString: idString)
        }
        completionHandler()
    }

    private func handle(action: String, taskIdString: String?) {
        guard let s = taskIdString, let id = UUID(uuidString: s) else { return }
        switch action {
        case ID.done:
            TaskService.shared.markDone(id: id)
        case ID.snooze:
            TaskService.shared.snooze(id: id)
        case ID.edit:
            break                           // opens the app; no deep link in the current UI
        default:
            break                           // plain tap: just opens the app
        }
    }
}
