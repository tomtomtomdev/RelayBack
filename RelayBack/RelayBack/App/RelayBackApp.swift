//
//  RelayBackApp.swift
//  RelayBack
//
//  Menu-bar agent entry point. No Dock icon (LSUIElement); the app lives entirely in the menu bar
//  via MenuBarExtra, with a standard Settings scene. See SPEC §7.
//
//  S10 wires the view state: a real `KeychainStore` backs `SettingsModel` (token + TOTP secret),
//  and `MenuBarModel` holds the popover's arm status + recent audit. The S11 lifecycle slice will
//  connect the poll loop / `AppCoordinator` so these update live.
//

import SwiftUI

@main
struct RelayBackApp: App {
    @State private var settings: SettingsModel
    @State private var menuBar = MenuBarModel()

    init() {
        _settings = State(initialValue: SettingsModel(store: KeychainStore()))
    }

    var body: some Scene {
        MenuBarExtra("RelayBack", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarRootView(model: menuBar)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: settings)
        }
    }
}
