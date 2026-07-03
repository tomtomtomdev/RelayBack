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
}
