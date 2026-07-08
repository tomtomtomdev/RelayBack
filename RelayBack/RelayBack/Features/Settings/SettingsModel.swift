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

    init(store: SecretStore,
         configStore: ConfigStore = UserDefaultsConfigStore(),
         loginItem: LoginItemControlling = SMAppServiceLoginItem(),
         auditReader: AuditReading? = nil,
         issuer: String = "RelayBack",
         account: String = "mac",
         idleTimeout: TimeInterval = 300,
         driftSteps: Int = 1) {
        self.store = store
        self.configStore = configStore
        self.loginItem = loginItem
        self.auditReader = auditReader
        self.issuer = issuer
        self.account = account
        self.armingConfig = ArmingConfigPresentation(idleTimeout: idleTimeout, driftSteps: driftSteps)
        self.allowlist = AllowlistDraft(configStore.allowlist())
        self.repos = configStore.repos()
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

    /// Writes the current repos to the config store and notifies the running guard (S16).
    private func persistRepos() {
        configStore.setRepos(repos)
        onReposChanged?(repos)
    }

    private static func trimmedOrNil(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
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
