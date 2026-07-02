//
//  SecretStore.swift
//  RelayBack
//
//  S5 — the abstraction the rest of the app depends on for secret persistence (FR-7).
//
//  Invariant I3: the bot token and TOTP secret live only in the macOS Keychain. This protocol
//  is the *only* seam through which they are read or written, so decision logic (AppCoordinator,
//  Settings) never touches Keychain APIs directly and is unit-testable against a fake. Secrets
//  are never logged, never written to the audit log, and never sent to Telegram.
//
//  Reads/writes are `throws` because the real backing store (Keychain Services) genuinely can
//  fail (locked keychain, OSStatus errors); a security app must surface that, not swallow it.
//  Setting a secret to `nil` deletes it. A missing secret reads back as `nil`, not an error.
//

import Foundation

protocol SecretStore {
    /// The Telegram bot token, or `nil` if none is stored.
    func botToken() throws -> String?
    /// Store the bot token, or clear it by passing `nil`.
    func setBotToken(_ token: String?) throws

    /// The raw TOTP shared secret (decoded bytes, as consumed by `TOTP`), or `nil` if none.
    func totpSecret() throws -> Data?
    /// Store the TOTP secret, or clear it by passing `nil`.
    func setTOTPSecret(_ secret: Data?) throws
}
