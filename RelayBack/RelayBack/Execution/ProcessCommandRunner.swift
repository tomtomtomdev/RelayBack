//
//  ProcessCommandRunner.swift
//  RelayBack
//
//  S7 — the real `CommandRunning` implementation. It spawns an allowlisted `Action` and captures its
//  output. As of S20 the spawn / capture / timeout core lives in the shared `ProcessSpawner` (so the
//  agent runner `ProcessClaudeRunner` uses the exact same audited path); this type is the thin adapter
//  that maps an `Action` onto it. The security invariants enforced at the spawn site are unchanged:
//    • I1 (no shell, ever): the action's absolute `executable` and fixed `arguments` array go straight
//      to `Process` (execve). Operator text is never concatenated into a command line and `/bin/sh -c`
//      is never used, so shell injection is impossible by construction.
//    • I4 (never elevate): the child inherits this process's (normal, non-root) privileges, runs with
//      a restricted PATH and no inherited operator environment.
//
//  `CommandRunnerTests` pins the behavior directly against safe builtins.
//

import Foundation

struct ProcessCommandRunner: CommandRunning {
    // Forwarding aliases so existing call sites/tests (`ProcessCommandRunner.restrictedPath`,
    // `.timeoutExitCode`, `.launchFailureExitCode`) are unchanged; the values live in `ProcessSpawner`.
    static let restrictedPath = ProcessSpawner.restrictedPath
    static let timeoutExitCode = ProcessSpawner.timeoutExitCode
    static let launchFailureExitCode = ProcessSpawner.launchFailureExitCode

    func run(_ action: Action) async -> CommandResult {
        await ProcessSpawner.run(executable: action.executable,
                                 arguments: action.arguments,          // I1: fixed array, never a shell.
                                 workingDirectory: action.workingDirectory,  // §4a: allowlisted root only.
                                 timeout: action.timeout)
    }
}
