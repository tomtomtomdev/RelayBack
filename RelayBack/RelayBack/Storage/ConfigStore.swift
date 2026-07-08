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
}
