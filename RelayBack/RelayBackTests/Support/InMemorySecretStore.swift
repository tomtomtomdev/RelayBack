//
//  InMemorySecretStore.swift
//  RelayBackTests
//
//  A `SecretStore` fake that keeps secrets in memory — no Keychain, no I/O. It defines the
//  contract the real `KeychainStore` must also satisfy (round-trip, missing → nil, overwrite,
//  nil → delete) and lets `AppCoordinator`/Settings logic (S8, S10) be tested without touching
//  the real Keychain.
//

import Foundation
@testable import RelayBack

final class InMemorySecretStore: SecretStore {
    private var storedBotToken: String?
    private var storedTOTPSecret: Data?
    private var storedPgyerApiKey: String?

    init(botToken: String? = nil, totpSecret: Data? = nil, pgyerApiKey: String? = nil) {
        storedBotToken = botToken
        storedTOTPSecret = totpSecret
        storedPgyerApiKey = pgyerApiKey
    }

    func botToken() throws -> String? { storedBotToken }
    func setBotToken(_ token: String?) throws { storedBotToken = token }

    func totpSecret() throws -> Data? { storedTOTPSecret }
    func setTOTPSecret(_ secret: Data?) throws { storedTOTPSecret = secret }

    func pgyerApiKey() throws -> String? { storedPgyerApiKey }
    func setPgyerApiKey(_ key: String?) throws { storedPgyerApiKey = key }
}
