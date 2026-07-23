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

    // MARK: - Add-repo form: folder chooser + draft (S20)

    @Test func chooseRepoRootFillsRootAndSuggestsNameFromFolder() {
        let picker = FakeFolderPicker(pathToReturn: "/Users/op/dev/RelayBack")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.chooseRepoRoot()
        #expect(model.newRepoRoot == "/Users/op/dev/RelayBack")
        #expect(model.newRepoName == "RelayBack")   // suggested from the chosen folder's name
    }

    @Test func chooseRepoRootDoesNotOverwriteATypedName() {
        let picker = FakeFolderPicker(pathToReturn: "/Users/op/dev/RelayBack")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.newRepoName = "myproj"
        model.chooseRepoRoot()
        #expect(model.newRepoRoot == "/Users/op/dev/RelayBack")
        #expect(model.newRepoName == "myproj")      // operator's name is kept
    }

    @Test func chooseRepoRootSuggestedNameIgnoresTrailingSlash() {
        let picker = FakeFolderPicker(pathToReturn: "/Users/op/dev/Notes/")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.chooseRepoRoot()
        #expect(model.newRepoName == "Notes")
    }

    @Test func cancellingTheFolderChooserLeavesTheDraftUnchanged() {
        let picker = FakeFolderPicker(pathToReturn: nil)   // operator cancelled
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.newRepoName = "keep"
        model.chooseRepoRoot()
        #expect(picker.chooseCount == 1)
        #expect(model.newRepoRoot == "")
        #expect(model.newRepoName == "keep")
    }

    @Test func submitNewRepoAddsFromDraftAndClearsItOnSuccess() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        model.newRepoName = "relayback"
        model.newRepoRoot = "/Users/op/dev/RelayBack"
        model.newRepoScheme = "RelayBack"
        #expect(model.submitNewRepo())
        #expect(config.repos() == [RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack", scheme: "RelayBack")])
        #expect(model.newRepoName == "")            // draft cleared on success
        #expect(model.newRepoRoot == "")
        #expect(model.newRepoScheme == "")
    }

    @Test func submitNewRepoKeepsDraftAndSurfacesErrorOnFailure() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        model.newRepoName = "x"      // no root chosen → rejected
        #expect(model.submitNewRepo() == false)
        #expect(model.newRepoName == "x")           // kept so the operator can fix it
        #expect(model.repoError != nil)
        #expect(model.repos.isEmpty)
    }

    // MARK: - Scripts (§4d — the operator-picked local-script allowlist, S34)

    @Test func loadsScriptsFromConfigStore() {
        let scripts = [ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh")]
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(scripts: scripts))
        #expect(model.scripts == scripts)
    }

    @Test func addScriptPersistsAndNotifies() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [ScriptConfig]?
        model.onScriptsChanged = { notified = $0 }

        #expect(model.addScript(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh"))
        let expected = [ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh")]
        #expect(config.scripts() == expected)     // persisted for next launch
        #expect(notified == expected)             // pushed to the running guard (hot-reload)
        #expect(model.scriptError == nil)
    }

    @Test func removeScriptPersistsAndNotifies() {
        let scripts = [ScriptConfig(label: "a", path: "/a.sh"), ScriptConfig(label: "b", path: "/b.sh")]
        let config = InMemoryConfigStore(scripts: scripts)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: [ScriptConfig]?
        model.onScriptsChanged = { notified = $0 }

        model.removeScript(label: "a")
        #expect(config.scripts() == [ScriptConfig(label: "b", path: "/b.sh")])
        #expect(notified == [ScriptConfig(label: "b", path: "/b.sh")])
    }

    @Test func addScriptRejectsDuplicateLabelWithoutPersistingOrNotifying() {
        let config = InMemoryConfigStore(scripts: [ScriptConfig(label: "deploy", path: "/x.sh")])
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notifyCount = 0
        model.onScriptsChanged = { _ in notifyCount += 1 }

        #expect(model.addScript(label: "deploy", path: "/y.sh") == false)
        #expect(model.scriptError != nil)
        #expect(notifyCount == 0)                 // no change → no persist, no hot-reload
        #expect(config.scripts() == [ScriptConfig(label: "deploy", path: "/x.sh")])   // unchanged
    }

    @Test func addScriptRejectsMissingLabelOrPath() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        #expect(model.addScript(label: "   ", path: "/x.sh") == false)
        #expect(model.addScript(label: "x", path: "  ") == false)
        #expect(model.scripts.isEmpty)
        #expect(model.scriptError != nil)
    }

    @Test func addScriptRejectsANonAbsolutePath() {
        // Fails closed at the Settings edge too: a relative path would map to nil in
        // ScriptConfig.toAction() (never runnable), so it is refused rather than silently stored (§4d / I1).
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        #expect(model.addScript(label: "deploy", path: "relative/deploy.sh") == false)
        #expect(model.scripts.isEmpty)
        #expect(model.scriptError != nil)
    }

    // MARK: - Add-script form: file/folder choosers + draft (S34)

    @Test func chooseScriptFileFillsPathAndSuggestsLabelFromFilename() {
        let picker = FakeFolderPicker(fileToReturn: "/Users/op/bin/deploy-staging.sh")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.chooseScriptFile()
        #expect(picker.chooseFileCount == 1)
        #expect(model.newScriptPath == "/Users/op/bin/deploy-staging.sh")
        #expect(model.newScriptLabel == "deploy-staging")   // suggested from the file name (no extension)
    }

    @Test func chooseScriptFileDoesNotOverwriteATypedLabel() {
        let picker = FakeFolderPicker(fileToReturn: "/Users/op/bin/deploy.sh")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.newScriptLabel = "My Deploy"
        model.chooseScriptFile()
        #expect(model.newScriptPath == "/Users/op/bin/deploy.sh")
        #expect(model.newScriptLabel == "My Deploy")        // operator's label is kept
    }

    @Test func cancellingTheScriptFileChooserLeavesTheDraftUnchanged() {
        let picker = FakeFolderPicker(fileToReturn: nil)   // operator cancelled
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.newScriptLabel = "keep"
        model.chooseScriptFile()
        #expect(picker.chooseFileCount == 1)
        #expect(model.newScriptPath == "")
        #expect(model.newScriptLabel == "keep")
    }

    @Test func chooseScriptWorkingDirectoryFillsItFromTheFolderBrowser() {
        let picker = FakeFolderPicker(pathToReturn: "/Users/op/dev/RelayBack")
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore(), folderPicker: picker)
        model.chooseScriptWorkingDirectory()
        #expect(picker.chooseCount == 1)
        #expect(model.newScriptWorkingDirectory == "/Users/op/dev/RelayBack")
    }

    @Test func submitNewScriptAddsFromDraftAndClearsItOnSuccess() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        model.newScriptLabel = "Deploy Staging"
        model.newScriptPath = "/Users/op/bin/deploy.sh"
        model.newScriptWorkingDirectory = "/Users/op/dev/RelayBack"
        model.newScriptTimeout = 600
        #expect(model.submitNewScript())
        #expect(config.scripts() == [ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh",
                                                  workingDirectory: "/Users/op/dev/RelayBack", timeout: 600)])
        #expect(model.newScriptLabel == "")                         // draft cleared on success
        #expect(model.newScriptPath == "")
        #expect(model.newScriptWorkingDirectory == "")
        #expect(model.newScriptTimeout == ScriptConfig.defaultTimeout)
    }

    @Test func submitNewScriptKeepsDraftAndSurfacesErrorOnFailure() {
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        model.newScriptLabel = "x"      // no file chosen → rejected
        #expect(model.submitNewScript() == false)
        #expect(model.newScriptLabel == "x")                        // kept so the operator can fix it
        #expect(model.scriptError != nil)
        #expect(model.scripts.isEmpty)
    }

    // MARK: - Claude agent action (§4b / S22 — capability pane view-state)

    @Test func loadsClaudeConfigFromConfigStore() {
        let profile = ClaudeProfile(executablePath: "/opt/homebrew/bin/claude",
                                    permission: .editsInRepo, timeout: 900, model: "opus")
        let config = InMemoryConfigStore(claudeEnabled: true, claudeProfile: profile)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        #expect(model.claudeEnabled)
        #expect(model.claudePermission == .editsInRepo)
        #expect(model.claudeExecutablePath == "/opt/homebrew/bin/claude")
        #expect(model.claudeTimeout == 900)
    }

    @Test func claudeDefaultsOffAndRestrictedWhenUnconfigured() {
        // I5: with no stored config the pane loads OFF + `restricted` (the fail-closed default), so
        // nothing is enabled and the dangerous profile is never the default.
        let model = SettingsModel(store: InMemorySecretStore(), configStore: InMemoryConfigStore())
        #expect(model.claudeEnabled == false)
        #expect(model.claudePermission == .restricted)
        #expect(model.claudeShowsBypassWarning == false)
    }

    @Test func setClaudeEnabledPersistsAndNotifies() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: (Bool, ClaudeProfile)?
        model.onClaudeConfigChanged = { notified = ($0, $1) }

        model.setClaudeEnabled(true)
        #expect(model.claudeEnabled)
        #expect(config.claudeEnabled())            // persisted for next launch
        #expect(notified?.0 == true)               // pushed to the running guard (hot-reload)
    }

    @Test func disablingClaudeNotifiesWithEnabledFalse() {
        // The PLAN's "disabling clears advertisement intent": the hot-reload carries enabled=false so
        // AppRuntime re-advertises without `/claude` and the guard refuses the next one (I5).
        let config = InMemoryConfigStore(claudeEnabled: true)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: (Bool, ClaudeProfile)?
        model.onClaudeConfigChanged = { notified = ($0, $1) }

        model.setClaudeEnabled(false)
        #expect(model.claudeEnabled == false)
        #expect(config.claudeEnabled() == false)
        #expect(notified?.0 == false)
    }

    @Test func fullBypassSelectionSetsTheWarningFlagAndPersists() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        model.setClaudePermission(.fullBypass)
        #expect(model.claudeShowsBypassWarning)                       // red-warning flag for the pane
        #expect(config.claudeProfile().permission == .fullBypass)     // persisted

        model.setClaudePermission(.restricted)
        #expect(model.claudeShowsBypassWarning == false)
    }

    @Test func settingTimeoutPersistsAndNotifies() {
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)
        var notified: ClaudeProfile?
        model.onClaudeConfigChanged = { _, profile in notified = profile }

        model.setClaudeTimeout(1200)
        #expect(config.claudeProfile().timeout == 1200)
        #expect(notified?.timeout == 1200)
    }

    @Test func chooseClaudeExecutableFillsPathViaFilePickerAndPersists() {
        let picker = FakeFolderPicker(fileToReturn: "/usr/local/bin/claude")
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config, folderPicker: picker)
        var notified: ClaudeProfile?
        model.onClaudeConfigChanged = { _, profile in notified = profile }

        model.chooseClaudeExecutable()
        #expect(picker.chooseFileCount == 1)
        #expect(model.claudeExecutablePath == "/usr/local/bin/claude")
        #expect(config.claudeProfile().executablePath == "/usr/local/bin/claude")
        #expect(notified?.executablePath == "/usr/local/bin/claude")
    }

    @Test func cancellingTheExecutableChooserLeavesTheConfigUnchanged() {
        let picker = FakeFolderPicker(fileToReturn: nil)   // operator cancelled
        let config = InMemoryConfigStore()
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config, folderPicker: picker)
        var notifyCount = 0
        model.onClaudeConfigChanged = { _, _ in notifyCount += 1 }

        model.chooseClaudeExecutable()
        #expect(picker.chooseFileCount == 1)
        #expect(model.claudeExecutablePath == "")   // untouched
        #expect(notifyCount == 0)                    // no change → no persist, no hot-reload
    }

    @Test func editingOneFieldPreservesTheOthersInTheReloadedProfile() {
        // Rebuilding the profile from the pane's fields must not drop the model override (which the
        // pane doesn't edit) nor an already-chosen executable/timeout.
        let profile = ClaudeProfile(executablePath: "/opt/claude", permission: .restricted,
                                    timeout: 600, model: "opus")
        let config = InMemoryConfigStore(claudeEnabled: false, claudeProfile: profile)
        let model = SettingsModel(store: InMemorySecretStore(), configStore: config)

        model.setClaudeEnabled(true)   // only touches the toggle
        let persisted = config.claudeProfile()
        #expect(persisted.executablePath == "/opt/claude")
        #expect(persisted.timeout == 600)
        #expect(persisted.model == "opus")            // preserved, not dropped
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
