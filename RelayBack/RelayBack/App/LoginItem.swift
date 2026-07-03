//
//  LoginItem.swift
//  RelayBack
//
//  S11 — the launch-at-login seam (FR-9 / SPEC §7: run unattended). `SettingsModel` toggles the
//  login item through this protocol so its glue is unit-testable against a fake; the real
//  implementation registers the app with `SMAppService` so macOS relaunches it after a reboot.
//
//  The real impl is thin (one `SMAppService.mainApp` call per operation) and verified by compiling
//  + the running app, not by a unit test — no test registers a real login item.
//

import Foundation
import ServiceManagement

/// Controls whether the app launches automatically at login.
protocol LoginItemControlling {
    /// Whether the app is currently registered to launch at login.
    var isEnabled: Bool { get }
    /// Registers (`true`) or unregisters (`false`) the app as a login item. Throws on failure so
    /// the caller can surface it rather than silently drifting from the requested state.
    func setEnabled(_ enabled: Bool) throws
}

/// The real login item, backed by `SMAppService.mainApp` (the app's own bundle).
struct SMAppServiceLoginItem: LoginItemControlling {
    var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
