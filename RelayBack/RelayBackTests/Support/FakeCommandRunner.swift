//
//  FakeCommandRunner.swift
//  RelayBackTests
//
//  A `CommandRunning` fake for the coordinator's decision-logic tests. It records the actions it
//  was asked to run (so a test can assert the runner was — or, for I2, was NOT — invoked) and
//  returns a canned `CommandResult`. No `Process`, no real spawning.
//

import Foundation
@testable import RelayBack

final class FakeCommandRunner: CommandRunning {
    /// The result every `run` returns; a test can set this to shape the output (e.g. oversized).
    var result: CommandResult

    private(set) var runActions: [Action] = []
    var runCount: Int { runActions.count }

    init(result: CommandResult = CommandResult(exitCode: 0, stdout: "ok", stderr: "")) {
        self.result = result
    }

    func run(_ action: Action) async -> CommandResult {
        runActions.append(action)
        return result
    }
}
