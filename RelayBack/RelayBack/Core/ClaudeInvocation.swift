//
//  ClaudeInvocation.swift
//  RelayBack
//
//  S20 — a pure, fully-resolved description of one headless Claude Code invocation (§4b). This is
//  the ONLY place operator text (the prompt) is turned into an argv, and it does so under invariant
//  I5 / I1:
//    • the prompt is a single inert argv token — always the value of `-p`, always the LAST element,
//      so it can never become a flag or the executable (there is no shell; metacharacters are literal);
//    • the executable and every permission flag come only from the configured `ClaudeProfile`.
//  It builds nothing runnable for an empty prompt (returns nil).
//
//  Note: unlike the fixed-allowlist path, the prompt is NOT validated — it is unvalidatable by
//  design (§4b). It is contained by the permission profile + active-repo cwd, not by a validator.
//

import Foundation

struct ClaudeInvocation: Equatable {
    /// Absolute path to the Claude Code executable (from the profile).
    let executable: String
    /// The resolved argv: permission flags (+ optional model) then `-p <prompt>`.
    let arguments: [String]
    /// The active repo root — set as the process cwd, bounding Claude Code's file reach (§4b).
    let workingDirectory: String
    /// Wall-clock limit for the run (from the profile).
    let timeout: TimeInterval

    /// Build the invocation for `prompt` in `repoRoot` under `profile`. Returns nil for an empty /
    /// whitespace-only prompt (nothing to run).
    static func build(prompt: String, repoRoot: String, profile: ClaudeProfile) -> ClaudeInvocation? {
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var arguments = permissionFlags(profile.permission)
        if let model = profile.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        // The prompt is bound to `-p` and placed LAST — the single inert operator token (I5). It can
        // never be read as a flag (it is a positional value) or as the executable.
        arguments += ["-p", prompt]

        return ClaudeInvocation(executable: profile.executablePath,
                                arguments: arguments,
                                workingDirectory: repoRoot,
                                timeout: profile.timeout)
    }

    /// The permission posture → Claude Code headless flags. Uses an ALLOW-list (not a blocklist) so a
    /// profile can only ever narrow what Claude Code may do:
    ///   • restricted  — read/search tools only.
    ///   • editsInRepo — read/search + edits; Bash denied entirely (a stricter, safer reading of
    ///     §4b's "destructive bash denied" — an allowlist beats enumerating destructive commands).
    ///   • fullBypass  — all permission checks skipped (explicit opt-in).
    private static func permissionFlags(_ profile: ClaudePermissionProfile) -> [String] {
        switch profile {
        case .restricted:
            return ["--allowedTools", "Read Grep Glob"]
        case .editsInRepo:
            return ["--allowedTools", "Read Grep Glob Edit Write", "--disallowedTools", "Bash"]
        case .fullBypass:
            return ["--dangerously-skip-permissions"]
        }
    }
}
