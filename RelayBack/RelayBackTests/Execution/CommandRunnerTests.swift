//
//  CommandRunnerTests.swift
//  RelayBackTests
//
//  S7 — the command runner is the one I/O type whose *logic is the real Process impl*, so it is
//  tested directly against safe system builtins (the single "real runner" exception CLAUDE grants:
//  short-lived `/bin/echo`-class commands only, no long-running processes). These tests also pin
//  the execution-hygiene invariants the runner must never regress:
//    • I1 — operator-supplied text is never shell-interpreted (args go straight to execve).
//    • I4 — the process runs as the normal (non-root) user with a restricted PATH, not elevated.
//
//  A `CommandRunning` fake for the coordinator's decision-logic tests arrives in S8; this slice
//  proves the real spawn/capture/timeout behavior.
//

import Foundation
import Testing
@testable import RelayBack

struct CommandRunnerTests {
    private let runner = ProcessCommandRunner()

    private func action(_ executable: String, _ args: [String], timeout: TimeInterval = 10)
        -> Action {
        Action(command: "/t", description: "test", executable: executable,
               arguments: args, timeout: timeout)
    }

    @Test func echoWritesStdoutWithZeroExit() async {
        let result = await runner.run(action("/bin/echo", ["hello"]))

        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello\n")
        #expect(result.stderr.isEmpty)
    }

    @Test func exitCodeIsCapturedFaithfully() async {
        // /usr/bin/false always exits 1 with no output.
        let result = await runner.run(action("/usr/bin/false", []))

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.isEmpty)
    }

    @Test func stderrIsCaptured() async {
        // ls of a missing path exits non-zero and diagnoses on stderr.
        let result = await runner.run(action("/bin/ls", ["/nonexistent-relayback-xyz"]))

        #expect(result.exitCode != 0)
        #expect(result.stdout.isEmpty)
        #expect(result.stderr.contains("nonexistent-relayback-xyz"))
    }

    @Test func timeoutTerminatesAndReports() async {
        // A 5s sleep under a 0.3s timeout must be killed — the call returns fast (not after 5s),
        // with the timeout sentinel exit code and an operator-visible note on stderr.
        let start = ContinuousClock.now
        let result = await runner.run(action("/bin/sleep", ["5"], timeout: 0.3))
        let elapsed = start.duration(to: .now)

        #expect(result.exitCode == ProcessCommandRunner.timeoutExitCode)
        #expect(result.stderr.lowercased().contains("timed out"))
        #expect(elapsed < .seconds(4))   // proves it was terminated, not waited out
    }

    @Test func operatorArgumentsAreNeverShellInterpreted() async {
        // I1: an argument full of shell metacharacters must reach the child verbatim. echo prints
        // its one argument as a single line, so exact equality proves it: a shell would have
        // expanded $HOME (→ a /Users path) and chained a second `echo pwned` on its own line.
        let payload = "$HOME && echo pwned"
        let result = await runner.run(action("/bin/echo", [payload]))

        #expect(result.exitCode == 0)
        #expect(result.stdout == payload + "\n")
    }

    @Test func runsAsCurrentUserNotRoot() async {
        // I4: no privilege escalation — the child runs as the current (non-root) user.
        let result = await runner.run(action("/usr/bin/id", ["-u"]))

        #expect(result.exitCode == 0)
        #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != "0")
    }

    @Test func spawnsWithRestrictedEnvironment() async {
        // Execution hygiene (SPEC §4.4): the child gets only a restricted PATH, not the operator's
        // inherited environment. `env` with a single-var environment prints exactly that line.
        let result = await runner.run(action("/usr/bin/env", []))

        #expect(result.exitCode == 0)
        #expect(result.stdout == "PATH=\(ProcessCommandRunner.restrictedPath)\n")
    }
}
