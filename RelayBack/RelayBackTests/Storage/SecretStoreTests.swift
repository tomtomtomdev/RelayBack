//
//  SecretStoreTests.swift
//  RelayBackTests
//
//  S5 — the secret-storage contract (FR-7, invariant I3). These tests drive the `SecretStore`
//  protocol through the in-memory fake: the same contract the real `KeychainStore` must honor.
//  Per PLAN/CLAUDE, the real Keychain impl is thin and NOT unit-tested (no test writes the real
//  Keychain); it only has to compile. Setting a secret to `nil` deletes it.
//

import Foundation
import Testing
@testable import RelayBack

struct SecretStoreTests {

    // MARK: - Missing → nil

    @Test func missingSecretsReadAsNil() throws {
        let store: SecretStore = InMemorySecretStore()
        #expect(try store.botToken() == nil)
        #expect(try store.totpSecret() == nil)
    }

    // MARK: - Round-trip

    @Test func botTokenRoundTrips() throws {
        let store = InMemorySecretStore()
        try store.setBotToken("123456:abcdef")
        #expect(try store.botToken() == "123456:abcdef")
    }

    @Test func totpSecretRoundTrips() throws {
        let store = InMemorySecretStore()
        let secret = Data([0x00, 0x01, 0x02, 0xFE, 0xFF])
        try store.setTOTPSecret(secret)
        #expect(try store.totpSecret() == secret)
    }

    // MARK: - Overwrite (last write wins)

    @Test func overwritingBotTokenKeepsTheLatestValue() throws {
        let store = InMemorySecretStore()
        try store.setBotToken("first")
        try store.setBotToken("second")
        #expect(try store.botToken() == "second")
    }

    // MARK: - Delete (nil clears)

    @Test func settingBotTokenToNilDeletesIt() throws {
        let store = InMemorySecretStore()
        try store.setBotToken("to-be-cleared")
        try store.setBotToken(nil)
        #expect(try store.botToken() == nil)
    }

    @Test func settingTOTPSecretToNilDeletesIt() throws {
        let store = InMemorySecretStore()
        try store.setTOTPSecret(Data([0xAB]))
        try store.setTOTPSecret(nil)
        #expect(try store.totpSecret() == nil)
    }

    // MARK: - Independence

    @Test func theTwoSecretsAreStoredIndependently() throws {
        let store = InMemorySecretStore()
        try store.setBotToken("tok")
        try store.setTOTPSecret(Data([0x10, 0x20]))
        // Clearing one must not disturb the other.
        try store.setBotToken(nil)
        #expect(try store.botToken() == nil)
        #expect(try store.totpSecret() == Data([0x10, 0x20]))
    }
}
