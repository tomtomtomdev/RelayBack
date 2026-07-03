//
//  UserDefaultsConfigStore.swift
//  RelayBack
//
//  S12 — the real `ConfigStore`, backed by `UserDefaults`. Deliberately thin: the allowlist is
//  non-secret app configuration, so `UserDefaults` (not the Keychain) is the right home for it.
//
//  Ids are stored as an array of `Int` (64-bit on macOS, so a Telegram `from.id` — which fits in
//  `Int64` — round-trips losslessly). All contract behavior (missing → empty, round-trip,
//  overwrite) is pinned by `ConfigStoreTests` against the in-memory fake, which this must match;
//  a focused smoke test exercises this impl against an isolated defaults suite.
//

import Foundation

struct UserDefaultsConfigStore: ConfigStore {
    private let defaults: UserDefaults
    private let key = "allowlist"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allowlist() -> [Int64] {
        (defaults.array(forKey: key) as? [Int])?.map(Int64.init) ?? []
    }

    func setAllowlist(_ ids: [Int64]) {
        defaults.set(ids.map(Int.init), forKey: key)
    }
}
