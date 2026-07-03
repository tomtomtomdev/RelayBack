//
//  FakeTelegramTransport.swift
//  RelayBackTests
//
//  A `TelegramTransport` fake that records every outbound call instead of touching the network.
//  It lets the coordinator (S8) be tested for exactly what it replies with — text vs. document,
//  to which chat — and lets the polling loop (S11) be driven with canned updates. No live network.
//

import Foundation
@testable import RelayBack

final class FakeTelegramTransport: TelegramTransport {
    /// Updates handed back by `getUpdates` (used by the S11 polling-loop tests).
    var updatesToReturn: [TelegramUpdate] = []

    private(set) var sentMessages: [(chatId: Int64, text: String)] = []
    private(set) var sentDocuments: [(chatId: Int64, filename: String, data: Data)] = []
    private(set) var registeredCommands: [BotCommand] = []

    func getUpdates(offset: Int64) async throws -> [TelegramUpdate] { updatesToReturn }

    func sendMessage(chatId: Int64, text: String) async throws {
        sentMessages.append((chatId, text))
    }

    func sendDocument(chatId: Int64, filename: String, data: Data) async throws {
        sentDocuments.append((chatId, filename, data))
    }

    func setMyCommands(_ commands: [BotCommand]) async throws {
        registeredCommands = commands
    }
}
