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

    private enum FakeError: Error { case boom }

    // MARK: - Launch at login (SMAppService glue, driven against the fake)

    @Test func launchAtLoginReflectsTheLoginItemOnLoad() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), loginItem: FakeLoginItem(isEnabled: true))
        #expect(model.launchAtLogin)
    }

    @Test func setLaunchAtLoginEnablesTheLoginItem() {
        let login = FakeLoginItem(isEnabled: false)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), loginItem: login)
        model.setLaunchAtLogin(true)
        #expect(login.isEnabled)
        #expect(model.launchAtLogin)
        #expect(model.lastError == nil)
    }

    @Test func setLaunchAtLoginFailureSurfacesErrorAndKeepsStateHonest() {
        let login = FakeLoginItem(isEnabled: false)
        login.errorToThrow = FakeError.boom
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), loginItem: login)
        model.setLaunchAtLogin(true)
        #expect(login.isEnabled == false)
        #expect(model.launchAtLogin == false)   // stays reflecting reality, not the failed request
        #expect(model.lastError != nil)
    }

    @Test func loadsExistingTokenFromTheStore() {
        let store = InMemorySecretStore(botToken: "abc:123")
        let model = SettingsModel(store: store, configStore: InMemoryConfigStore())
        #expect(model.botToken == "abc:123")
    }

    @Test func saveTokenPersistsTrimmedValue() throws {
        let store = InMemorySecretStore()
        let model = SettingsModel(store: store, configStore: InMemoryConfigStore())
        model.botToken = "  abc:123  "
        model.saveToken()
        #expect(try store.botToken() == "abc:123")
        #expect(model.lastError == nil)
    }

    @Test func savingAnEmptyTokenClearsIt() throws {
        let store = InMemorySecretStore(botToken: "abc:123")
        let model = SettingsModel(store: store, configStore: InMemoryConfigStore())
        model.botToken = "   "
        model.saveToken()
        #expect(try store.botToken() == nil)
    }

    @Test func addIdClearsFieldOnSuccessAndKeepsFieldOnFailure() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        model.newIdText = "42"
        #expect(model.addId() == .added(42))
        #expect(model.newIdText == "")
        #expect(model.allowlist.ids == [42])

        model.newIdText = "nope"
        #expect(model.addId() == .invalid)
        #expect(model.newIdText == "nope")   // kept so the operator can fix it
    }

    @Test func invalidAddSurfacesAnErrorMessage() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        model.newIdText = "@handle"
        #expect(model.addId() == .invalid)
        #expect(model.allowlistError != nil)   // no more silent rejection
    }

    @Test func duplicateAddSurfacesAnErrorMessage() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(allowlist: [42]))
        model.newIdText = "42"
        #expect(model.addId() == .duplicate)
        #expect(model.allowlistError != nil)
    }

    @Test func successfulAddClearsAnyPriorAllowlistError() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        model.newIdText = "nope"
        _ = model.addId()
        #expect(model.allowlistError != nil)

        model.newIdText = "42"
        #expect(model.addId() == .added(42))
        #expect(model.allowlistError == nil)   // cleared on success
    }

    // MARK: - Allowlist persistence (S12 — ConfigStore-backed, notifies the live guard)

    @Test func loadsAllowlistFromConfigStore() {
        let config = InMemoryConfigStore(allowlist: [7, 42])
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        #expect(model.allowlist.ids == [7, 42])
    }

    @Test func addIdPersistsAndNotifies() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [Int64]?
        model.onAllowlistChanged = { notified = $0 }

        model.newIdText = "42"
        #expect(model.addId() == .added(42))
        #expect(config.allowlist() == [42])      // persisted for next launch
        #expect(notified == [42])                // pushed to the running guard (hot-reload)
    }

    @Test func removeIdPersistsAndNotifies() {
        let config = InMemoryConfigStore(allowlist: [7, 42])
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [Int64]?
        model.onAllowlistChanged = { notified = $0 }

        model.removeId(7)
        #expect(config.allowlist() == [42])
        #expect(notified == [42])
    }

    @Test func aFailedDuplicateAddDoesNotRepersistOrNotify() {
        let config = InMemoryConfigStore(allowlist: [42])
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notifyCount = 0
        model.onAllowlistChanged = { _ in notifyCount += 1 }

        model.newIdText = "42"
        #expect(model.addId() == .duplicate)
        #expect(notifyCount == 0)                // no change → no persist, no hot-reload
    }

    // MARK: - Repos (S16 — ConfigStore-backed, notifies the live guard)

    @Test func loadsReposFromConfigStore() {
        let repos = [RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack")]
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(repos: repos))
        #expect(model.repos == repos)
    }

    @Test func addRepoPersistsAndNotifies() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [RepoConfig]?
        model.onReposChanged = { notified = $0 }

        #expect(model.addRepo(name: "relayback", root: "/Users/op/dev/RelayBack", scheme: "RelayBack"))
        let expected = [RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack", scheme: "RelayBack")]
        #expect(config.repos() == expected)     // persisted for next launch
        #expect(notified == expected)           // pushed to the running guard (hot-reload)
        #expect(model.repoError == nil)
    }

    @Test func removeRepoPersistsAndNotifies() {
        let repos = [RepoConfig(name: "a", root: "/a"), RepoConfig(name: "b", root: "/b")]
        let config = InMemoryConfigStore(repos: repos)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [RepoConfig]?
        model.onReposChanged = { notified = $0 }

        model.removeRepo(name: "a")
        #expect(config.repos() == [RepoConfig(name: "b", root: "/b")])
        #expect(notified == [RepoConfig(name: "b", root: "/b")])
    }

    @Test func addRepoRejectsDuplicateNameWithoutPersistingOrNotifying() {
        let config = InMemoryConfigStore(repos: [RepoConfig(name: "relayback", root: "/x")])
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notifyCount = 0
        model.onReposChanged = { _ in notifyCount += 1 }

        #expect(model.addRepo(name: "relayback", root: "/y") == false)
        #expect(model.repoError != nil)
        #expect(notifyCount == 0)               // no change → no persist, no hot-reload
        #expect(config.repos() == [RepoConfig(name: "relayback", root: "/x")])   // unchanged
    }

    @Test func addRepoRejectsMissingNameOrRoot() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        #expect(model.addRepo(name: "   ", root: "/x") == false)
        #expect(model.addRepo(name: "x", root: "  ") == false)
        #expect(model.repos.isEmpty)
        #expect(model.repoError != nil)
    }

    @Test func noSecretMeansNoQR() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        #expect(model.hasSecret == false)
        #expect(model.otpauthURI == nil)
        #expect(model.totpSecretBase32 == nil)
    }

    @Test func loadsExistingSecretAsBase32AndURI() {
        let seed = Data("12345678901234567890".utf8)
        let model = SettingsModel(store: InMemorySecretStore(totpSecret: seed), configStore: InMemoryConfigStore())
        #expect(model.hasSecret)
        #expect(model.totpSecretBase32 == "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ")
        #expect(model.otpauthURI == "otpauth://totp/RelayBack:mac"
            + "?secret=GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ"
            + "&issuer=RelayBack&algorithm=SHA1&digits=6&period=30")
    }

    @Test func generateSecretPersistsAndExposesIt() throws {
        let store = InMemorySecretStore()
        let model = SettingsModel(store: store, configStore: InMemoryConfigStore())
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
        let model = SettingsModel(store: store, configStore: InMemoryConfigStore())
        let old = model.totpSecret
        model.generateSecret()
        #expect(model.totpSecret != old)
        #expect(try store.totpSecret() == model.totpSecret)
    }
}
