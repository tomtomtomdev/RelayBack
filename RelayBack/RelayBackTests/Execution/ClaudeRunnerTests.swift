//
//  ClaudeRunnerTests.swift
//  RelayBackTests
//
//  S20 — the real `ProcessClaudeRunner` is thin (it builds the invocation and delegates to the same
//  `ProcessSpawner` the S7 runner uses), so like the S7 `CommandRunnerTests` it is smoke-tested
//  directly against safe system builtins standing in for the Claude Code binary — the one "real
//  runner" exception CLAUDE grants. cwd forwarding + timeout/kill are already pinned for the shared
//  spawner via `CommandRunnerTests`; here we prove the agent runner's own path: build → spawn.
//

import Foundation
import Testing
@testable import RelayBack

struct ClaudeRunnerTests {
    private let runner = ProcessClaudeRunner()

    @Test func realRunnerSpawnsStandInBinaryAndCapturesOutput() async {
        // /bin/echo stands in for `claude`: BSD echo prints every non-`-n` argument verbatim and
        // exits 0, so this proves the real spawn path (build invocation → execve) end-to-end with no
        // Claude Code installed. fullBypass keeps the flags simple; the prompt is the trailing token.
        let profile = ClaudeProfile(executablePath: "/bin/echo", permission: .fullBypass, timeout: 10)
        let result = await runner.run(prompt: "hello agent", repoRoot: "/tmp", profile: profile)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "--dangerously-skip-permissions -p hello agent\n")
    }

    @Test func realRunnerPassesAHostilePromptThroughAsOneInertArgument() async {
        // I5 end-to-end: even a prompt full of shell metacharacters reaches the child verbatim as a
        // single argument (a shell would have expanded $HOME and chained `echo pwned`).
        let payload = "$HOME && echo pwned"
        let profile = ClaudeProfile(executablePath: "/bin/echo", permission: .fullBypass, timeout: 10)
        let result = await runner.run(prompt: payload, repoRoot: "/tmp", profile: profile)
        #expect(result.exitCode == 0)
        #expect(result.stdout == "--dangerously-skip-permissions -p \(payload)\n")
    }

    @Test func emptyPromptDoesNotSpawn() async {
        // Defense in depth for I5: an empty prompt yields the no-spawn result, not a launched process.
        let profile = ClaudeProfile(executablePath: "/bin/echo", permission: .fullBypass, timeout: 10)
        let result = await runner.run(prompt: "   ", repoRoot: "/tmp", profile: profile)
        #expect(result.stdout.isEmpty)
        #expect(result.exitCode == ProcessCommandRunner.launchFailureExitCode)
    }
}
