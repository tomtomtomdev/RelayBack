//
//  SettingsModelTests.swift
//  RelayBackTests
//
//  S10 — the Settings view state, driven against the in-memory `SecretStore` fake (no Keychain).
//  Proves the token/secret persistence glue and that secrets flow only through the store seam
//  (invariant I3): the model reads/writes the token and TOTP secret via `SecretStore`, never
//  anywhere else.
//

import Foundation
import Testing
@testable import RelayBack

struct SettingsModelTests {

    @Test func loadsExistingTokenFromTheStore() {
        let store = InMemorySecretStore(botToken: "abc:123")
        let model = SettingsModel(store: store)
        #expect(model.botToken == "abc:123")
    }

    @Test func saveTokenPersistsTrimmedValue() throws {
        let store = InMemorySecretStore()
        let model = SettingsModel(store: store)
        model.botToken = "  abc:123  "
        model.saveToken()
        #expect(try store.botToken() == "abc:123")
        #expect(model.lastError == nil)
    }

    @Test func savingAnEmptyTokenClearsIt() throws {
        let store = InMemorySecretStore(botToken: "abc:123")
        let model = SettingsModel(store: store)
        model.botToken = "   "
        model.saveToken()
        #expect(try store.botToken() == nil)
    }

    @Test func addIdClearsFieldOnSuccessAndKeepsFieldOnFailure() {
        let model = SettingsModel(store: InMemorySecretStore())
        model.newIdText = "42"
        #expect(model.addId() == .added(42))
        #expect(model.newIdText == "")
        #expect(model.allowlist.ids == [42])

        model.newIdText = "nope"
        #expect(model.addId() == .invalid)
        #expect(model.newIdText == "nope")   // kept so the operator can fix it
    }

    @Test func noSecretMeansNoQR() {
        let model = SettingsModel(store: InMemorySecretStore())
        #expect(model.hasSecret == false)
        #expect(model.otpauthURI == nil)
        #expect(model.totpSecretBase32 == nil)
    }

    @Test func loadsExistingSecretAsBase32AndURI() {
        let seed = Data("12345678901234567890".utf8)
        let model = SettingsModel(store: InMemorySecretStore(totpSecret: seed))
        #expect(model.hasSecret)
        #expect(model.totpSecretBase32 == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(model.otpauthURI == "otpauth://totp/RelayBack:mac"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            + "&issuer=RelayBack&algorithm=SHA1&digits=6&period=30")
    }

    @Test func generateSecretPersistsAndExposesIt() throws {
        let store = InMemorySecretStore()
        let model = SettingsModel(store: store)
        model.generateSecret()

        let stored = try #require(try store.totpSecret())
        #expect(stored.count == 20)                       // 160-bit secret
        #expect(model.totpSecret == stored)               // model mirrors the store
        #expect(model.totpSecretBase32 == Base32.encode(stored))
        #expect(model.otpauthURI?.hasPrefix("otpauth://totp/RelayBack:mac?secret=") == true)
        #expect(model.lastError == nil)
    }

    @Test func generateSecretReplacesTheOldOne() throws {
        let store = InMemorySecretStore(totpSecret: Data("12345678901234567890".utf8))
        let model = SettingsModel(store: store)
        let old = model.totpSecret
        model.generateSecret()
        #expect(model.totpSecret != old)
        #expect(try store.totpSecret() == model.totpSecret)
    }
}
