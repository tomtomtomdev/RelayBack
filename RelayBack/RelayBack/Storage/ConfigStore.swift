//
//  ConfigStore.swift
//  RelayBack
//
//  S12 — the abstraction for persisting *non-secret* configuration: the authorization allowlist
//  (the set of Telegram `from.id` values allowed to command the agent). This is the only seam
//  through which the allowlist is read or written, so `SettingsModel` and `AppRuntime` never touch
//  the backing store directly and are unit-testable against a fake.
//
//  Unlike `SecretStore`, this holds no secret (invariant I3 is unaffected) and is **non-throwing**:
//  the real backing store is `UserDefaults`, whose reads never fail, and a config write is
//  best-effort background bookkeeping — it must never interrupt the operator. It also fails closed:
//  a missing / unreadable allowlist reads back as empty, so the agent authorizes no one (invariant
//  I2 — an absent config can only ever *narrow* who may run commands, never widen it).
//

import Foundation

protocol ConfigStore {
    /// The persisted authorization allowlist (Telegram `from.id` values); empty if none is stored.
    func allowlist() -> [Int64]
    /// Persist the authorization allowlist, replacing any previous value.
    func setAllowlist(_ ids: [Int64])
    /// The persisted repo allowlist (§4a working-directory allowlist, S16); empty if none is stored.
    /// Fails closed like the allowlist: a missing / unreadable value reads back as empty, so an
    /// absent config can only ever *narrow* what the dev-workflow actions can reach, never widen it.
    func repos() -> [RepoConfig]
    /// Persist the repo allowlist, replacing any previous value.
    func setRepos(_ repos: [RepoConfig])

    // MARK: - Claude agent action (§4b / S20)

    /// Whether the `/claude` agent action is enabled. **Fails closed to `false`**: like the
    /// allowlist, an absent config can only ever narrow capability, never widen it (I5). Off by
    /// default — nothing spawns until the operator opts in (S22).
    func claudeEnabled() -> Bool
    /// Persist the `/claude` capability toggle.
    func setClaudeEnabled(_ enabled: Bool)
    /// The persisted Claude Code profile (executable path, permission posture, timeout, model), or
    /// the fail-closed `ClaudeProfile.default` (no executable, `restricted`) if none is stored.
    func claudeProfile() -> ClaudeProfile
    /// Persist the Claude Code profile, replacing any previous value.
    func setClaudeProfile(_ profile: ClaudeProfile)
}
