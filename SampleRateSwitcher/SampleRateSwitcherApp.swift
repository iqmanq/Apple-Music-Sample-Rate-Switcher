//
//  SampleRateSwitcherApp.swift
//  SampleRateSwitcher
//
//  Created by Iqraa Manuel on 5/21/25.
//

import SwiftUI

@main
struct SampleRateSwitcherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView() // No settings window
        }
    }
}
