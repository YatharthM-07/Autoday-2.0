//
//  AutoDay_2_0App.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 11/10/26.
//

import SwiftUI
import UIKit

@main
struct AutoDay_2_0App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        ProfileDefaults.applyLaunchMode()             // start in the user's default Auto / Manual mode
        _ = PersistenceController.shared              // open the Core Data store
        NotificationService.shared.configure()        // Done / Snooze / Edit actions
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

/// Portrait everywhere except while the week view is open.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }
}

enum OrientationLock {
    @MainActor
    static func lock(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.windows.first?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { @Sendable error in
            print("Orientation request failed:", error)
        }
    }
}
