//
//  ClaudeRunning.swift
//  RelayBack
//
//  S20 — the seam between the app's decision logic and a headless Claude Code run (§4b / FR-11).
//  Kept SEPARATE from `CommandRunning` on purpose: the fixed-allowlist path and the free-text agent
//  path are visibly distinct. An `Action`'s arguments are always fixed or validated, whereas a
//  `/claude` run carries the one unvalidated free-text parameter (the prompt), contained by the
//  permission profile rather than a validator. `AppCoordinator` (S21) depends on this protocol and
//  is tested against `FakeClaudeRunner`; the real implementation is `ProcessClaudeRunner`.
//

import Foundation

protocol ClaudeRunning {
    /// Run Claude Code headless with `prompt` (a single inert argv token, §4b / I5) in `repoRoot`,
    /// under `profile`'s permission posture and timeout. Non-throwing: launch failures and timeouts
    /// fold into the `CommandResult`, so the coordinator always has exactly one thing to format,
    /// deliver, and audit.
    func run(prompt: String, repoRoot: String, profile: ClaudeProfile) async -> CommandResult
}
