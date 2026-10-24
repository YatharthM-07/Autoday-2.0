//
//  AutoDay_2_0App.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 11/10/26.
//

import SwiftUI

@main
struct AutoDay_2_0App: App {

    init() {
        _ = PersistenceController.shared              // open the Core Data store
        NotificationService.shared.configure()        // Done / Snooze / Edit actions
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
