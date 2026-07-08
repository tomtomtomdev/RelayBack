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

    init(allowlist: [Int64] = [], repos: [RepoConfig] = []) {
        ids = allowlist
        repoConfigs = repos
    }

    func allowlist() -> [Int64] { ids }
    func setAllowlist(_ ids: [Int64]) { self.ids = ids }

    func repos() -> [RepoConfig] { repoConfigs }
    func setRepos(_ repos: [RepoConfig]) { repoConfigs = repos }
}
