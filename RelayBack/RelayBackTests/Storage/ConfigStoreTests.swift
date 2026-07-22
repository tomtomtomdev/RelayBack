//
//  ConfigStoreTests.swift
//  RelayBackTests
//
//  S12 — the non-secret config store (the authorization allowlist). Driven against the in-memory
//  fake, which defines the contract the real `UserDefaultsConfigStore` must also satisfy
//  (missing → empty, round-trip, overwrite-last-wins). This is where the identity allowlist (SPEC
//  §4 control 1 / invariant I2) is persisted between launches; unlike `SecretStore` it holds no
//  secret, so it is non-throwing and best-effort.
//
//  A tiny smoke test exercises the real `UserDefaultsConfigStore` against an isolated, throwaway
//  suite (never the standard defaults) so no state leaks between runs.
//

import Foundation
import Testing
@testable import RelayBack

struct ConfigStoreTests {

    @Test func missingAllowlistIsEmpty() {
        let store = InMemoryConfigStore()
        #expect(store.allowlist() == [])
    }

    @Test func allowlistRoundTrips() {
        let store = InMemoryConfigStore()
        store.setAllowlist([7, 42, 111])
        #expect(store.allowlist() == [7, 42, 111])
    }

    @Test func setAllowlistOverwritesLastWins() {
        let store = InMemoryConfigStore(allowlist: [1, 2, 3])
        store.setAllowlist([9])
        #expect(store.allowlist() == [9])
    }

    // Real impl, isolated suite — proves the UserDefaults round-trip without touching .standard.
    @Test func userDefaultsStoreRoundTripsInIsolatedSuite() throws {
        let suite = "com.RelayBack.tests.config"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsConfigStore(defaults: defaults)
        #expect(store.allowlist() == [])
        store.setAllowlist([5, 6_000_000_000])   // includes an id beyond Int32 range
        #expect(store.allowlist() == [5, 6_000_000_000])
    }

    // MARK: - Repos (S16 — the §4a working-directory allowlist)

    @Test func missingReposIsEmpty() {
        let store = InMemoryConfigStore()
        #expect(store.repos() == [])
    }

    @Test func reposRoundTrip() {
        let store = InMemoryConfigStore()
        let repos = [
            RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                       scheme: "RelayBack", destination: "platform=macOS"),
            RepoConfig(name: "notes", root: "/Users/op/dev/Notes"),
        ]
        store.setRepos(repos)
        #expect(store.repos() == repos)
    }

    @Test func setReposOverwritesLastWins() {
        let store = InMemoryConfigStore(repos: [RepoConfig(name: "a", root: "/a")])
        store.setRepos([RepoConfig(name: "b", root: "/b")])
        #expect(store.repos() == [RepoConfig(name: "b", root: "/b")])
    }

    // Real impl, isolated suite — repos persist as JSON and round-trip (incl. the optional fields).
    @Test func userDefaultsStoreRoundTripsReposInIsolatedSuite() throws {
        let suite = "com.RelayBack.tests.config.repos"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsConfigStore(defaults: defaults)
        #expect(store.repos() == [])
        let repos = [
            RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                       scheme: "RelayBack", destination: "platform=macOS",
                       simulatorDevice: "iPhone 15"),
            RepoConfig(name: "notes", root: "/Users/op/dev/Notes"),
        ]
        store.setRepos(repos)
        #expect(store.repos() == repos)
    }

    // MARK: - Claude agent config (§4b / S20)

    @Test func missingClaudeEnabledIsFalse() {
        // Fails closed like the allowlist — an absent config can only narrow capability (I5).
        #expect(InMemoryConfigStore().claudeEnabled() == false)
    }

    @Test func missingClaudeProfileIsTheFailClosedDefault() {
        let store = InMemoryConfigStore()
        #expect(store.claudeProfile() == ClaudeProfile.default)
        #expect(store.claudeProfile().permission == .restricted)
        #expect(store.claudeProfile().executablePath.isEmpty)
    }

    @Test func claudeEnabledAndProfileRoundTrip() {
        let store = InMemoryConfigStore()
        store.setClaudeEnabled(true)
        let profile = ClaudeProfile(executablePath: "/usr/local/bin/claude",
                                    permission: .editsInRepo, timeout: 900, model: "opus")
        store.setClaudeProfile(profile)
        #expect(store.claudeEnabled() == true)
        #expect(store.claudeProfile() == profile)
    }

    // MARK: - PGYER upload URL (§4c / S27)

    @Test func missingPgyerUploadURLIsTheDefaultEndpoint() {
        // Fails closed to the known PGYER endpoint — the upload can only ever target that unless
        // the operator deliberately changes it (§4c). Not a secret; the key lives in SecretStore.
        #expect(InMemoryConfigStore().pgyerUploadURL() == "https://www.pgyer.com/apiv2/app/upload")
    }

    @Test func pgyerUploadURLRoundTrips() {
        let store = InMemoryConfigStore()
        store.setPgyerUploadURL("https://example.test/api/upload")
        #expect(store.pgyerUploadURL() == "https://example.test/api/upload")
    }

    @Test func blankPgyerUploadURLFailsClosedToTheDefault() {
        // A stored empty/whitespace value must not become the target — fail closed to the default.
        let store = InMemoryConfigStore()
        store.setPgyerUploadURL("   ")
        #expect(store.pgyerUploadURL() == "https://www.pgyer.com/apiv2/app/upload")
    }

    // Real impl, isolated suite — the URL round-trips and a fresh store reads the default.
    @Test func userDefaultsStoreRoundTripsPgyerUploadURLInIsolatedSuite() throws {
        let suite = "com.RelayBack.tests.config.pgyer"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsConfigStore(defaults: defaults)
        #expect(store.pgyerUploadURL() == "https://www.pgyer.com/apiv2/app/upload")
        store.setPgyerUploadURL("https://example.test/api/upload")
        #expect(store.pgyerUploadURL() == "https://example.test/api/upload")
    }

    // Real impl, isolated suite — the toggle and the (JSON-encoded) profile round-trip.
    @Test func userDefaultsStoreRoundTripsClaudeConfigInIsolatedSuite() throws {
        let suite = "com.RelayBack.tests.config.claude"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = UserDefaultsConfigStore(defaults: defaults)
        #expect(store.claudeEnabled() == false)
        #expect(store.claudeProfile() == .default)

        store.setClaudeEnabled(true)
        let profile = ClaudeProfile(executablePath: "/opt/claude", permission: .fullBypass,
                                    timeout: 1200, model: nil)
        store.setClaudeProfile(profile)
        #expect(store.claudeEnabled() == true)
        #expect(store.claudeProfile() == profile)
    }
}
