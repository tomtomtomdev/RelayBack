//
//  SettingsModel.swift
//  RelayBack
//
//  S10 — the @Observable view state behind the Settings screen (FR-9). It owns no I/O of its own:
//  secret persistence goes through the injected `SecretStore` seam (Keychain in the real app, the
//  in-memory fake in tests), so token save/load and TOTP-secret generation are unit-testable
//  without touching the real Keychain (invariant I3 — secrets never leave that seam).
//
//  The allowlist is edited as a pure `AllowlistDraft`, loaded from and persisted through the
//  injected `ConfigStore` seam (S12). Every change is also pushed to `onAllowlistChanged`, which
//  `AppRuntime` uses to hot-reload the running `AuthGuard` so an edit takes effect immediately
//  (a removed id is revoked at once — invariant I2) without restarting the agent.
//  The launch-at-login toggle goes through the injected `LoginItemControlling` seam (real
//  `SMAppService` in the app, a fake in tests), so its glue is unit-tested (S11).
//

import Foundation
import Security

@Observable
final class SettingsModel {
    /// Editable bot-token field; persisted to the Keychain on `saveToken()`.
    var botToken: String
    /// Text field for the next allowlist id to add.
    var newIdText: String = ""
    /// Whether the app launches at login. Mirrors the real login-item state; changed only via
    /// `setLaunchAtLogin` so it never drifts from what `SMAppService` actually did.
    private(set) var launchAtLogin: Bool

    /// The numeric Telegram id allowlist being edited (validated, unique, sorted).
    private(set) var allowlist: AllowlistDraft
    /// The raw TOTP secret currently stored, or nil if none is set.
    private(set) var totpSecret: Data?
    /// A short, secret-free message surfaced to the UI after a failed Keychain operation.
    private(set) var lastError: String?
    /// A short message surfaced under the allowlist section when an add is rejected (invalid input
    /// or a duplicate), so a rejected id is never silently dropped. Cleared on a successful add.
    private(set) var allowlistError: String?

    /// Called after every allowlist change with the new ids, so the composition root can hot-reload
    /// the running `AuthGuard` (S12). Not set in tests that only assert persistence.
    var onAllowlistChanged: (([Int64]) -> Void)?

    /// The configured repo allowlist being edited (§4a / S16), loaded from and persisted through
    /// the `ConfigStore`. Every change is pushed to `onReposChanged` so the running guard hot-reloads.
    private(set) var repos: [RepoConfig]
    /// A short message surfaced under the repos section when an add is rejected (missing fields or a
    /// duplicate name), so a rejected repo is never silently dropped. Cleared on a successful add.
    private(set) var repoError: String?
    /// Called after every repo change with the new list, so the composition root can hot-reload the
    /// running `AuthGuard` (S16), mirroring `onAllowlistChanged`.
    var onReposChanged: (([RepoConfig]) -> Void)?

    /// The configured local-script allowlist being edited (§4d / S34), loaded from and persisted
    /// through the `ConfigStore`. Every change is pushed to `onScriptsChanged` so the running guard's
    /// action registry hot-reloads (a removed script can no longer run — I2), mirroring the repos.
    private(set) var scripts: [ScriptConfig]
    /// A short message surfaced under the scripts section when an add is rejected (missing fields, a
    /// non-absolute path, or a duplicate label), so a rejected script is never silently dropped.
    private(set) var scriptError: String?
    /// Called after every scripts change with the new list, so the composition root can hot-reload the
    /// running `AuthGuard`'s registry (S34), mirroring `onReposChanged`.
    var onScriptsChanged: (([ScriptConfig]) -> Void)?

    // Draft fields for the "Add script" form (S34 — mirrors the add-repo draft). `newScriptPath` is
    // filled by `chooseScriptFile()` from a native file browser rather than typed, so the script that
    // gets registered is a real file the operator pointed at (never chat-supplied — §4d / I1).
    /// Draft script label (the `/run` picker entry); suggested from the chosen file unless already set.
    var newScriptLabel = ""
    /// Draft absolute script path; set by `chooseScriptFile()` from the file browser, never typed.
    var newScriptPath = ""
    /// Draft working directory (optional); set by `chooseScriptWorkingDirectory()`, never typed.
    var newScriptWorkingDirectory = ""
    /// Draft run timeout in seconds; the runner terminates the script if it exceeds this.
    var newScriptTimeout: TimeInterval = ScriptConfig.defaultTimeout

    // Draft fields for the "Add repo" form (S20 — moved here from the view so the folder-chooser
    // and name-suggestion glue is unit-testable). `newRepoRoot` is filled by `chooseRepoRoot()`
    // from a native folder browser rather than typed; `submitNewRepo()` commits and clears them.
    /// Draft repo name (`/cd <name>` target); suggested from the chosen folder unless already set.
    var newRepoName = ""
    /// Draft working directory; set by `chooseRepoRoot()` from the folder browser, never typed.
    var newRepoRoot = ""
    /// Draft `xcodebuild -scheme` (optional, for `/build`).
    var newRepoScheme = ""
    /// Draft `xcodebuild -destination` (optional, for `/build`).
    var newRepoDestination = ""
    /// Draft simulator device (optional, for `/sim`).
    var newRepoSimulator = ""

    // MARK: - Claude agent action (§4b / S22 — the capability pane's editable state)
    //
    // Loaded from and persisted through the `ConfigStore`, mirroring the allowlist/repos. Every edit
    // persists **and** fires `onClaudeConfigChanged`, so the composition root hot-reloads the running
    // guard and re-advertises `/claude` immediately (S22 decision — parity with the allowlist/repos
    // hot-reload, not "apply on next arm"). `claudeEnabled` defaults OFF and `fullBypass` is never the
    // default (invariant I5) — the fail-closed `ConfigStore.default` guarantees both.

    /// Whether the `/claude` agent action is enabled. OFF until the operator deliberately opts in (I5).
    private(set) var claudeEnabled: Bool
    /// The permission posture a headless `/claude` run is bounded by. `.fullBypass` is the warned opt-in.
    private(set) var claudePermission: ClaudePermissionProfile
    /// Absolute path to the Claude Code executable; picked from a file browser (S22), never typed, so
    /// the binary that gets spawned is a real file the operator pointed at rather than a mistyped string.
    private(set) var claudeExecutablePath: String
    /// Wall-clock limit for an agent run, in seconds (an agent turn can take minutes).
    private(set) var claudeTimeout: TimeInterval
    /// The persisted model override (`--model`), preserved across edits — the pane doesn't edit it, so
    /// it must round-trip rather than be dropped when the profile is rebuilt from the pane's fields.
    private var claudeModel: String?

    /// Called after every Claude-config change with the new `(enabled, profile)`, so the composition
    /// root can hot-reload the running guard + re-advertise `/claude` (S22), mirroring `onReposChanged`.
    var onClaudeConfigChanged: ((Bool, ClaudeProfile) -> Void)?

    /// True when the selected profile skips all permission checks — drives the pane's red warning so
    /// `fullBypass` is never chosen without a visible caution (I5).
    var claudeShowsBypassWarning: Bool { claudePermission == .fullBypass }

    /// Live transport reachability shown in the Connection pane (S13f). The composition root
    /// (`AppRuntime`) probes the bot at startup and pushes the result here; the pane renders it via
    /// `ConnectionStatePresentation`. Starts `.connecting` until the first probe resolves.
    var connectionState: ConnectionState = .connecting

    let issuer: String
    let account: String

    /// The app's fixed arming config, surfaced read-only in the Security pane (S13d). Mirrors the
    /// values `AppRuntime`/`AuthGuard`/`TOTP` are pinned to (300s idle, ±1 drift) — display, not edit.
    let armingConfig: ArmingConfigPresentation

    /// Newest-first, color-coded rows for the Settings Audit pane (S13f). Refreshed on demand from
    /// the injected `AuditReading`; empty until `refreshAuditRows()` runs (or when no reader is set).
    private(set) var auditRows: [AuditRowPresentation] = []

    private let store: SecretStore
    private let configStore: ConfigStore
    private let loginItem: LoginItemControlling
    private let auditReader: AuditReading?
    private let folderPicker: FolderPicking

    init(store: SecretStore,
         configStore: ConfigStore = UserDefaultsConfigStore(),
         loginItem: LoginItemControlling = SMAppServiceLoginItem(),
         auditReader: AuditReading? = nil,
         folderPicker: FolderPicking = NSOpenPanelFolderPicker(),
         issuer: String = "RelayBack",
         account: String = "mac",
         idleTimeout: TimeInterval = 300,
         driftSteps: Int = 1) {
        self.store = store
        self.configStore = configStore
        self.loginItem = loginItem
        self.auditReader = auditReader
        self.folderPicker = folderPicker
        self.issuer = issuer
        self.account = account
        self.armingConfig = ArmingConfigPresentation(idleTimeout: idleTimeout, driftSteps: driftSteps)
        self.allowlist = AllowlistDraft(configStore.allowlist())
        self.repos = configStore.repos()
        self.scripts = configStore.scripts()
        let claudeProfile = configStore.claudeProfile()
        self.claudeEnabled = configStore.claudeEnabled()
        self.claudePermission = claudeProfile.permission
        self.claudeExecutablePath = claudeProfile.executablePath
        self.claudeTimeout = claudeProfile.timeout
        self.claudeModel = claudeProfile.model
        self.botToken = (try? store.botToken()) ?? ""
        self.totpSecret = (try? store.totpSecret()) ?? nil
        self.launchAtLogin = loginItem.isEnabled
    }

    // MARK: - Launch at login

    /// Registers/unregisters the app as a login item, updating `launchAtLogin` to what actually
    /// took effect. On failure it surfaces a short message and leaves the flag reflecting reality.
    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try loginItem.setEnabled(enabled)
            launchAtLogin = loginItem.isEnabled
            lastError = nil
        } catch {
            launchAtLogin = loginItem.isEnabled
            lastError = "Could not update launch-at-login."
        }
    }

    // MARK: - Audit log (read side, S13f)

    /// Reloads the Audit pane's rows from the log (newest-first). Best-effort: with no reader or an
    /// unreadable log it leaves an empty table. Call when the pane appears so it shows fresh history.
    func refreshAuditRows(limit: Int = 200) {
        let entries = auditReader?.recentEntries(limit: limit) ?? []
        auditRows = AuditRowPresentation.rows(from: entries)
    }

    // MARK: - Bot token

    /// Persists the trimmed `botToken` to the Keychain, clearing it when the field is empty.
    func saveToken() {
        let trimmed = botToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.setBotToken(trimmed.isEmpty ? nil : trimmed)
            lastError = nil
        } catch {
            lastError = "Could not save the bot token."
        }
    }

    // MARK: - Allowlist

    /// Validates and adds `newIdText`; clears the field on success. Returns the outcome so the
    /// view can surface "invalid" / "already added". Persists and hot-reloads only on a real change.
    @discardableResult
    func addId() -> AllowlistDraft.AddResult {
        let result = allowlist.add(newIdText)
        switch result {
        case .added:
            newIdText = ""
            allowlistError = nil
            persistAllowlist()
        case .invalid:
            allowlistError = "Not a valid Telegram id — enter the numeric from.id."
        case .duplicate:
            allowlistError = "That id is already on the allowlist."
        }
        return result
    }

    func removeId(_ id: Int64) {
        let before = allowlist.ids
        allowlist.remove(id)
        if allowlist.ids != before { persistAllowlist() }
    }

    /// Writes the current allowlist to the config store and notifies the running guard (S12).
    private func persistAllowlist() {
        configStore.setAllowlist(allowlist.ids)
        onAllowlistChanged?(allowlist.ids)
    }

    // MARK: - Repos (§4a working-directory allowlist, S16)

    /// Validates and adds a repo; returns whether it was added. A repo needs a non-empty name and
    /// root, and its name must be unique. Optional build-config fields are trimmed to nil when blank.
    /// Persists and hot-reloads only on a real change.
    @discardableResult
    func addRepo(name: String, root: String, scheme: String? = nil,
                 destination: String? = nil, simulatorDevice: String? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let root = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !root.isEmpty else {
            repoError = "A repo needs a name and an absolute path."
            return false
        }
        guard !repos.contains(where: { $0.name == name }) else {
            repoError = "A repo named “\(name)” already exists."
            return false
        }
        repos.append(RepoConfig(name: name, root: root,
                                scheme: Self.trimmedOrNil(scheme),
                                destination: Self.trimmedOrNil(destination),
                                simulatorDevice: Self.trimmedOrNil(simulatorDevice)))
        repoError = nil
        persistRepos()
        return true
    }

    func removeRepo(name: String) {
        let before = repos
        repos.removeAll { $0.name == name }
        if repos != before { persistRepos() }
    }

    /// Opens the native folder browser and, on a selection, fills `newRepoRoot` with the chosen
    /// directory — and, when the operator hasn't already named the repo, suggests the folder's own
    /// name. A cancelled chooser leaves the draft untouched. (S20 — the working directory is picked,
    /// never typed, so it always resolves to a real directory.)
    func chooseRepoRoot() {
        guard let path = folderPicker.chooseFolder() else { return }
        newRepoRoot = path
        if newRepoName.trimmingCharacters(in: .whitespaces).isEmpty {
            newRepoName = Self.suggestedName(forRoot: path)
        }
    }

    /// Commits the drafted repo via `addRepo`; on success clears the draft fields, on failure keeps
    /// them (with `repoError` set) so the operator can fix the input. Returns whether it was added.
    @discardableResult
    func submitNewRepo() -> Bool {
        guard addRepo(name: newRepoName, root: newRepoRoot,
                      scheme: newRepoScheme, destination: newRepoDestination,
                      simulatorDevice: newRepoSimulator) else { return false }
        newRepoName = ""; newRepoRoot = ""; newRepoScheme = ""
        newRepoDestination = ""; newRepoSimulator = ""
        return true
    }

    /// The suggested repo name for a chosen directory: its last path component (trailing slashes
    /// ignored), empty for the filesystem root. Purely derived so the folder-chooser suggestion is
    /// tested without a real panel; the operator can override it before adding.
    static func suggestedName(forRoot root: String) -> String {
        let last = (root.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        return last == "/" ? "" : last
    }

    /// Writes the current repos to the config store and notifies the running guard (S16).
    private func persistRepos() {
        configStore.setRepos(repos)
        onReposChanged?(repos)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Scripts (§4d operator-picked local-script allowlist, S34)

    /// Validates and adds a script; returns whether it was added. A script needs a non-empty label and
    /// an **absolute** path (a relative path would map to nil in `ScriptConfig.toAction()` — never
    /// runnable — so it fails closed here too, §4d / I1), and its label must be unique. Persists and
    /// hot-reloads only on a real change.
    @discardableResult
    func addScript(label: String, path: String, workingDirectory: String? = nil,
                   timeout: TimeInterval = ScriptConfig.defaultTimeout) -> Bool {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !path.isEmpty else {
            scriptError = "A script needs a name and a chosen file."
            return false
        }
        guard path.hasPrefix("/") else {
            scriptError = "The script path must be absolute — choose the file with the browser."
            return false
        }
        guard !scripts.contains(where: { $0.label == label }) else {
            scriptError = "A script named “\(label)” already exists."
            return false
        }
        scripts.append(ScriptConfig(label: label, path: path,
                                    workingDirectory: Self.trimmedOrNil(workingDirectory),
                                    timeout: timeout))
        scriptError = nil
        persistScripts()
        return true
    }

    func removeScript(label: String) {
        let before = scripts
        scripts.removeAll { $0.label == label }
        if scripts != before { persistScripts() }
    }

    /// Opens the native file browser and, on a selection, fills `newScriptPath` with the chosen file —
    /// and, when the operator hasn't already named the script, suggests the file's name (no extension).
    /// A cancelled chooser leaves the draft untouched. (S34 — the script is picked, never typed, so its
    /// path is always an absolute, real file; chat never supplies it — §4d / I1.)
    func chooseScriptFile() {
        guard let path = folderPicker.chooseFile() else { return }
        newScriptPath = path
        if newScriptLabel.trimmingCharacters(in: .whitespaces).isEmpty {
            newScriptLabel = Self.suggestedLabel(forPath: path)
        }
    }

    /// Opens the native folder browser and, on a selection, fills the optional working directory.
    /// A cancelled chooser leaves the draft untouched.
    func chooseScriptWorkingDirectory() {
        guard let path = folderPicker.chooseFolder() else { return }
        newScriptWorkingDirectory = path
    }

    /// Commits the drafted script via `addScript`; on success clears the draft (timeout back to the
    /// default), on failure keeps it (with `scriptError` set) so the operator can fix the input.
    @discardableResult
    func submitNewScript() -> Bool {
        guard addScript(label: newScriptLabel, path: newScriptPath,
                        workingDirectory: newScriptWorkingDirectory,
                        timeout: newScriptTimeout) else { return false }
        newScriptLabel = ""; newScriptPath = ""; newScriptWorkingDirectory = ""
        newScriptTimeout = ScriptConfig.defaultTimeout
        return true
    }

    /// The suggested label for a chosen script file: its file name with the extension dropped
    /// (`deploy-staging.sh` → `deploy-staging`). Purely derived so the suggestion is tested without a
    /// real panel; the operator can override it before adding.
    static func suggestedLabel(forPath path: String) -> String {
        let file = (path.trimmingCharacters(in: .whitespaces) as NSString).lastPathComponent
        return (file as NSString).deletingPathExtension
    }

    /// Writes the current scripts to the config store and notifies the running guard (S34).
    private func persistScripts() {
        configStore.setScripts(scripts)
        onScriptsChanged?(scripts)
    }

    // MARK: - Claude agent action (§4b / S22)

    /// Enables or disables the `/claude` capability, persisting and hot-reloading at once (I5).
    func setClaudeEnabled(_ enabled: Bool) {
        claudeEnabled = enabled
        persistClaude()
    }

    /// Selects the permission posture a headless run is bounded by. `.fullBypass` flips
    /// `claudeShowsBypassWarning` for the pane's red caution.
    func setClaudePermission(_ permission: ClaudePermissionProfile) {
        claudePermission = permission
        persistClaude()
    }

    /// Sets the agent run timeout (seconds).
    func setClaudeTimeout(_ timeout: TimeInterval) {
        claudeTimeout = timeout
        persistClaude()
    }

    /// Opens the native file browser and, on a selection, points the executable path at the chosen
    /// file (S22) — never typed, so the binary that gets spawned is one the operator actually pointed
    /// at. A cancelled chooser leaves the config untouched (no persist, no hot-reload).
    func chooseClaudeExecutable() {
        guard let path = folderPicker.chooseFile() else { return }
        claudeExecutablePath = path
        persistClaude()
    }

    /// The profile assembled from the pane's fields, preserving the non-edited `model` override.
    private var currentClaudeProfile: ClaudeProfile {
        ClaudeProfile(executablePath: claudeExecutablePath,
                      permission: claudePermission,
                      timeout: claudeTimeout,
                      model: claudeModel)
    }

    /// Persists the toggle + profile and notifies the running guard (S22), mirroring `persistRepos`.
    /// The hot-reload is the parity decision: a capability edit takes effect without a restart, and
    /// disabling refuses the next `/claude` at once — the guard gate is the real I5 enforcement.
    private func persistClaude() {
        let profile = currentClaudeProfile
        configStore.setClaudeEnabled(claudeEnabled)
        configStore.setClaudeProfile(profile)
        onClaudeConfigChanged?(claudeEnabled, profile)
    }

    // MARK: - TOTP secret

    /// Whether a TOTP secret is set (drives showing the QR vs. a "generate" prompt).
    var hasSecret: Bool { totpSecret != nil }

    /// Base32 of the current secret (for manual entry), or nil when none is set.
    var totpSecretBase32: String? { totpSecret.map(Base32.encode) }

    /// The `otpauth://` provisioning URI to render as a QR, or nil when no secret is set.
    var otpauthURI: String? {
        totpSecret.map { OtpAuthURI.totp(secret: $0, issuer: issuer, account: account) }
    }

    /// Generates a fresh random 160-bit secret (RFC 6238's minimum for HMAC-SHA-1), stores it in
    /// the Keychain, and exposes it for the QR. Replaces any existing secret.
    func generateSecret() {
        guard let bytes = Self.randomSecret(byteCount: 20) else {
            lastError = "Could not generate a secret."
            return
        }
        do {
            try store.setTOTPSecret(bytes)
            totpSecret = bytes
            lastError = nil
        } catch {
            lastError = "Could not save the secret."
        }
    }

    private static func randomSecret(byteCount: Int) -> Data? {
        var bytes = Data(count: byteCount)
        let status = bytes.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, raw.baseAddress!)
        }
        return status == errSecSuccess ? bytes : nil
    }
}
