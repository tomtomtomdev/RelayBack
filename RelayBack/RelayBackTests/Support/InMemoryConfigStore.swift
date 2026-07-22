//
//  InMemoryConfigStore.swift
//  RelayBackTests
//
//  A `ConfigStore` fake that keeps the allowlist in memory — no UserDefaults, no I/O. It defines
//  the contract the real `UserDefaultsConfigStore` must also satisfy (missing → empty, round-trip,
//  overwrite) and lets `SettingsModel`/`AppRuntime` wiring (S12) be tested without touching the
//  real defaults.
//

import Foundation
@testable import RelayBack

final class InMemoryConfigStore: ConfigStore {
    private var ids: [Int64]
    private var repoConfigs: [RepoConfig]
    private var claudeIsEnabled: Bool
    private var claudeProfileValue: ClaudeProfile
    private var pgyerURL: String?

    init(allowlist: [Int64] = [], repos: [RepoConfig] = [],
         claudeEnabled: Bool = false, claudeProfile: ClaudeProfile = .default,
         pgyerUploadURL: String? = nil) {
        ids = allowlist
        repoConfigs = repos
        claudeIsEnabled = claudeEnabled
        claudeProfileValue = claudeProfile
        pgyerURL = pgyerUploadURL
    }

    func allowlist() -> [Int64] { ids }
    func setAllowlist(_ ids: [Int64]) { self.ids = ids }

    func repos() -> [RepoConfig] { repoConfigs }
    func setRepos(_ repos: [RepoConfig]) { repoConfigs = repos }

    func claudeEnabled() -> Bool { claudeIsEnabled }
    func setClaudeEnabled(_ enabled: Bool) { claudeIsEnabled = enabled }
    func claudeProfile() -> ClaudeProfile { claudeProfileValue }
    func setClaudeProfile(_ profile: ClaudeProfile) { claudeProfileValue = profile }

    func pgyerUploadURL() -> String { Self.resolvedPgyerUploadURL(pgyerURL) }
    func setPgyerUploadURL(_ url: String) { pgyerURL = url }
}
