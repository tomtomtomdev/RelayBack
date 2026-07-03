//
//  MenuBarModelTests.swift
//  RelayBackTests
//
//  S13b — the armed popover's read-only action list and the last-result / disarm hooks the
//  coordinator feeds. The action cards mirror `ActionRegistry` but carry NO runnable payload
//  (command + description only), so the UI edge can never spawn a process (invariant I1).
//

import Foundation
import Testing
@testable import RelayBack

struct MenuBarModelTests {

    @Test func actionsMirrorTheRegistryReadOnly() {
        let model = MenuBarModel()
        let expected = ActionRegistry.seed.actions.map { ActionSummary($0) }

        #expect(model.actions == expected)
        #expect(model.actions.map(\.command) == ["/uptime", "/disk", "/whoami"])
        // I1 at the UI edge: a summary exposes only the command + description — no executable,
        // arguments, or timeout that the popover could turn into a spawn.
        #expect(model.actions.first?.description == ActionRegistry.seed.actions.first?.description)
    }

    @Test func lastResultDefaultsToNil() {
        #expect(MenuBarModel().lastResult == nil)
    }

    @Test func disarmHookIsInvokable() {
        let model = MenuBarModel()
        var disarmed = false
        model.disarm = { disarmed = true }
        model.disarm()
        #expect(disarmed)
    }
}
