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

        // The popover mirrors the seed registry. That registry is now empty (the legacy
        // diagnostics were removed), so the armed popover shows its "No actions can run" state.
        #expect(model.actions == expected)
        #expect(model.actions.isEmpty)
    }

    @Test func summaryExposesOnlyCommandAndDescription() {
        // I1 at the UI edge: a summary carries only the command + description — no executable,
        // arguments, or timeout that the popover could turn into a spawn.
        let action = Action(command: "/disk",
                            description: "Disk usage, human-readable",
                            executable: "/bin/df",
                            arguments: ["-h"],
                            timeout: 10)
        let summary = ActionSummary(action)
        #expect(summary.command == "/disk")
        #expect(summary.description == "Disk usage, human-readable")
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
