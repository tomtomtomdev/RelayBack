//
//  ClaudeProfile.swift
//  RelayBack
//
//  S20 — configuration for the `/claude` agent action (§4b). Pure value types, so they live in Core.
//  The prompt is NOT stored here: it arrives per-message and is the sole free-text parameter (§4b).
//
//  Because the operator is remote and cannot answer interactive permission prompts, the permission
//  PROFILE — not a human — is the safety boundary for a headless run. `restricted` is the default;
//  `fullBypass` is an explicit, warned opt-in (S22). Paired with `claudeEnabled` defaulting OFF
//  (ConfigStore), nothing spawns until the operator deliberately configures it — invariant I5.
//

import Foundation

/// The permission posture Claude Code runs under when invoked headless (§4b).
enum ClaudePermissionProfile: String, Codable, CaseIterable, Equatable {
    /// Read/search tools only — no edits, no bash. The default.
    case restricted
    /// Read/search + edits; bash denied (v1: all bash — an allowlist, not a destructive-cmd blocklist).
    case editsInRepo
    /// All permission checks skipped — accepts arbitrary execution scoped to the active repo.
    case fullBypass
}

/// The persisted (non-secret) Claude Code configuration, stored via `ConfigStore`.
struct ClaudeProfile: Equatable, Codable {
    /// Absolute path to the Claude Code executable. Never derived from operator text (I1 / I5).
    var executablePath: String
    /// The permission posture the headless run is bounded by.
    var permission: ClaudePermissionProfile
    /// Wall-clock limit for a run; the runner terminates Claude Code if exceeded. Longer than a
    /// normal action — an agent turn can take minutes.
    var timeout: TimeInterval
    /// Optional model override (`--model`); nil uses Claude Code's own default.
    var model: String?

    init(executablePath: String = "",
         permission: ClaudePermissionProfile = .restricted,
         timeout: TimeInterval = 600,
         model: String? = nil) {
        self.executablePath = executablePath
        self.permission = permission
        self.timeout = timeout
        self.model = model
    }

    /// The fail-closed default: no executable configured, most-restricted profile. With
    /// `claudeEnabled` OFF by default, nothing can spawn until the operator configures it (S22).
    static let `default` = ClaudeProfile()
}
