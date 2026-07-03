//
//  SettingsModel.swift
//  RelayBack
//
//  S10 — the @Observable view state behind the Settings screen (FR-9). It owns no I/O of its own:
//  secret persistence goes through the injected `SecretStore` seam (Keychain in the real app, the
//  in-memory fake in tests), so token save/load and TOTP-secret generation are unit-testable
//  without touching the real Keychain (invariant I3 — secrets never leave that seam).
//
//  The allowlist is edited as a pure `AllowlistDraft`; wiring the saved allowlist into the running
//  coordinator (and persisting it) is the S11 lifecycle slice. The login-item toggle here is UI
//  only — `SMAppService` is likewise wired in S11.
//

import Foundation
import Security

@Observable
final class SettingsModel {
    /// Editable bot-token field; persisted to the Keychain on `saveToken()`.
    var botToken: String
    /// Text field for the next allowlist id to add.
    var newIdText: String = ""
    /// UI state of the launch-at-login toggle. Wired to `SMAppService` in S11.
    var launchAtLogin: Bool = false

    /// The numeric Telegram id allowlist being edited (validated, unique, sorted).
    private(set) var allowlist: AllowlistDraft
    /// The raw TOTP secret currently stored, or nil if none is set.
    private(set) var totpSecret: Data?
    /// A short, secret-free message surfaced to the UI after a failed Keychain operation.
    private(set) var lastError: String?

    let issuer: String
    let account: String

    private let store: SecretStore

    init(store: SecretStore,
         issuer: String = "RelayBack",
         account: String = "mac",
         allowlist: [Int64] = []) {
        self.store = store
        self.issuer = issuer
        self.account = account
        self.allowlist = AllowlistDraft(allowlist)
        self.botToken = (try? store.botToken()) ?? ""
        self.totpSecret = (try? store.totpSecret()) ?? nil
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
    /// view can surface "invalid" / "already added".
    @discardableResult
    func addId() -> AllowlistDraft.AddResult {
        let result = allowlist.add(newIdText)
        if case .added = result { newIdText = "" }
        return result
    }

    func removeId(_ id: Int64) {
        allowlist.remove(id)
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
