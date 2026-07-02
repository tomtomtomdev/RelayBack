//
//  KeychainStore.swift
//  RelayBack
//
//  S5 — the real `SecretStore` backed by macOS Keychain Services (invariant I3, FR-7).
//
//  Deliberately thin. Per PLAN/CLAUDE this impl is verified by *compilation only* — no unit
//  test may write the real Keychain, so its runtime behavior is exercised manually via the
//  Settings UI (S10). All contract behavior (round-trip, missing → nil, overwrite, nil → delete)
//  is pinned by `SecretStoreTests` against the in-memory fake, which this must match.
//
//  Storage model: one generic-password item per secret, keyed by a fixed service + account.
//  Values are stored as `Data`; the bot token is UTF-8 encoded/decoded on the way through.
//  Items are marked `AfterFirstUnlock` so the background agent can read them unattended once
//  the user has logged in (the login keychain is unlocked at login and stays unlocked).
//

import Foundation
import Security

struct KeychainStore: SecretStore {
    /// Namespaces this app's items in the keychain. Not a secret.
    private let service: String

    /// Fixed account identifiers for the two stored secrets. Not secrets — just item keys.
    private enum Account {
        static let botToken = "botToken"
        static let totpSecret = "totpSecret"
    }

    init(service: String = "com.RelayBack") {
        self.service = service
    }

    // MARK: - SecretStore

    func botToken() throws -> String? {
        guard let data = try read(account: Account.botToken) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func setBotToken(_ token: String?) throws {
        try write(token?.data(using: .utf8), account: Account.botToken)
    }

    func totpSecret() throws -> Data? {
        try read(account: Account.totpSecret)
    }

    func setTOTPSecret(_ secret: Data?) throws {
        try write(secret, account: Account.totpSecret)
    }

    // MARK: - Keychain plumbing

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Upsert (`nil` deletes). Update-then-add avoids a duplicate-item error on overwrite.
    private func write(_ data: Data?, account: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedStatus(status)
            }
            return
        }

        let update = SecItemUpdate(
            baseQuery(account: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecItemNotFound {
            var addQuery = baseQuery(account: account)
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let add = SecItemAdd(addQuery as CFDictionary, nil)
            guard add == errSecSuccess else { throw KeychainError.unexpectedStatus(add) }
        } else if update != errSecSuccess {
            throw KeychainError.unexpectedStatus(update)
        }
    }
}

/// A Keychain Services call returned an unexpected `OSStatus`. Carries the raw status only —
/// never a secret value (invariant I3).
enum KeychainError: Error, Equatable {
    case unexpectedStatus(OSStatus)
}
