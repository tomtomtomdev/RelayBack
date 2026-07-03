//
//  RelayBackApp.swift
//  RelayBack
//
//  Menu-bar agent entry point. No Dock icon (LSUIElement); the app lives entirely in the menu bar
//  via MenuBarExtra, with a standard Settings scene. See SPEC §7.
//
//  S11 wires the lifecycle. `AppRuntime` is the composition root — it owns the view models and the
//  polling loop. An `NSApplicationDelegate` starts long-polling at launch (so the agent runs
//  unattended, not only when the popover is opened) and stops it on termination for a graceful
//  shutdown. The loop survives network blips and sleep/wake via `PollLoop`'s backoff.
//

import SwiftUI
import AppKit

@main
struct RelayBackApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("RelayBack", systemImage: "dot.radiowaves.left.and.right") {
            MenuBarRootView(model: delegate.runtime.menuBar)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: delegate.runtime.settings)
        }
    }
}

/// Owns the runtime and ties its polling lifecycle to the app's: begin at launch, end on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let runtime = AppRuntime()

    func applicationDidFinishLaunching(_ notification: Notification) {
        runtime.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        runtime.stop()
    }
}
