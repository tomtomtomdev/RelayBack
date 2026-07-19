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
    private let reposKey = "repos"
    private let claudeEnabledKey = "claudeEnabled"
    private let claudeProfileKey = "claudeProfile"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func allowlist() -> [Int64] {
        (defaults.array(forKey: key) as? [Int])?.map(Int64.init) ?? []
    }

    func setAllowlist(_ ids: [Int64]) {
        defaults.set(ids.map(Int.init), forKey: key)
    }

    // Repos carry optional fields, so they are stored as JSON (not a plist array). Fails closed:
    // a missing or undecodable blob reads back as empty (§4a / S16).
    func repos() -> [RepoConfig] {
        guard let data = defaults.data(forKey: reposKey),
              let repos = try? JSONDecoder().decode([RepoConfig].self, from: data) else { return [] }
        return repos
    }

    func setRepos(_ repos: [RepoConfig]) {
        guard let data = try? JSONEncoder().encode(repos) else { return }
        defaults.set(data, forKey: reposKey)
    }

    // Claude config (§4b / S20). Enabled is a plain Bool — absent reads back `false` (fails closed,
    // I5). The profile carries optional fields, so it is stored as JSON like repos; a missing or
    // undecodable blob reads back as the fail-closed `ClaudeProfile.default`.
    func claudeEnabled() -> Bool {
        defaults.bool(forKey: claudeEnabledKey)
    }

    func setClaudeEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: claudeEnabledKey)
    }

    func claudeProfile() -> ClaudeProfile {
        guard let data = defaults.data(forKey: claudeProfileKey),
              let profile = try? JSONDecoder().decode(ClaudeProfile.self, from: data) else { return .default }
        return profile
    }

    func setClaudeProfile(_ profile: ClaudeProfile) {
        guard let data = try? JSONEncoder().encode(profile) else { return }
        defaults.set(data, forKey: claudeProfileKey)
    }
}
