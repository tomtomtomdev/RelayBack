//
//  RelayBackApp.swift
//  RelayBack
//
//  Menu-bar agent entry point. No Dock icon (LSUIElement); the app lives
//  entirely in the menu bar via MenuBarExtra. See SPEC §7.
//

import SwiftUI

@main
struct RelayBackApp: App {
    var body: some Scene {
        MenuBarExtra("RelayBack", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarRootView()
        }
        .menuBarExtraStyle(.window)
    }
}
