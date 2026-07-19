//
//  FakeClaudeRunner.swift
//  RelayBackTests
//
//  A `ClaudeRunning` fake for the coordinator's decision-logic tests (S21). It records each call's
//  (prompt, repoRoot, profile) so a test can assert the agent runner was — or, for invariant I5, was
//  NOT — invoked, and returns a canned `CommandResult`. No `Process`, no real spawning.
//

import Foundation
@testable import RelayBack

final class FakeClaudeRunner: ClaudeRunning {
    /// The result every `run` returns; a test can set this to shape the output (e.g. oversized).
    var result: CommandResult
    private(set) var calls: [(prompt: String, repoRoot: String, profile: ClaudeProfile)] = []
    var runCount: Int { calls.count }

    init(result: CommandResult = CommandResult(exitCode: 0, stdout: "claude ok", stderr: "")) {
        self.result = result
    }

    func run(prompt: String, repoRoot: String, profile: ClaudeProfile) async -> CommandResult {
        calls.append((prompt, repoRoot, profile))
        return result
    }
}
