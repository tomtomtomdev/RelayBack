//
//  ProcessClaudeRunner.swift
//  RelayBack
//
//  S20 — the real `ClaudeRunning`. It resolves the invocation with the pure `ClaudeInvocation.build`
//  (which enforces I5: the prompt is one inert `-p` token, never a flag or the executable) and spawns
//  it through the shared `ProcessSpawner` — the SAME audited spawn / timeout / hygiene core the S7
//  command runner uses (I1: fixed executable + argv → execve, never a shell; I4: normal user,
//  restricted PATH, no inherited env). Per CLAUDE this thin real impl is verified by a focused smoke
//  test against a safe stand-in binary; there is no pure logic hiding behind it to fake.
//

import Foundation

struct ProcessClaudeRunner: ClaudeRunning {
    func run(prompt: String, repoRoot: String, profile: ClaudeProfile) async -> CommandResult {
        guard let invocation = ClaudeInvocation.build(prompt: prompt, repoRoot: repoRoot, profile: profile) else {
            // The guard already refuses an empty prompt before reaching here (S21); this is defense
            // in depth so the real runner never spawns Claude Code with nothing to do.
            return CommandResult(exitCode: ProcessSpawner.launchFailureExitCode, stdout: "",
                                 stderr: "empty prompt; nothing to run")
        }
        return await ProcessSpawner.run(executable: invocation.executable,
                                        arguments: invocation.arguments,
                                        workingDirectory: invocation.workingDirectory,
                                        timeout: invocation.timeout)
    }
}
