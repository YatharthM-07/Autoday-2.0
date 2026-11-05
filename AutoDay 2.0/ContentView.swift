//
//  ContentView.swift
//  AutoDay 2.0
//
//  Created by Archita Saxena on 11/10/26.
//

import SwiftUI

struct ContentView: View {
    @AppStorage(ProfileKeys.appearance) private var appearance = 0

    var body: some View {
        TimelineView()
            .preferredColorScheme(ProfileDefaults.colorScheme(appearance))
    }
}

#Preview {
    ContentView()
}
