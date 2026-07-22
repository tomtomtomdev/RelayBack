//
//  FakeTelegramTransport.swift
//  RelayBackTests
//
//  A `TelegramTransport` fake that records every outbound call instead of touching the network.
//  It lets the coordinator (S8) be tested for exactly what it replies with — text vs. document,
//  to which chat — and lets the polling loop (S11) be driven with scripted `getUpdates` results
//  (successes and failures) without any live network.
//

import Foundation
@testable import RelayBack

/// One scripted answer for a `getUpdates` call: a batch of updates, or a transport error.
enum GetUpdatesResult {
    case updates([TelegramUpdate])
    case failure(Error)
}

final class FakeTelegramTransport: TelegramTransport {
    /// Scripted answers, consumed in order — one per `getUpdates` call (S11 poll-loop tests).
    var getUpdatesScript: [GetUpdatesResult] = []
    /// Fired once, the first time a `getUpdates` call runs past the end of the script. Lets a test
    /// know the loop has drained the script (e.g. recovered after failures) before it stops it.
    var onScriptExhausted: (() -> Void)?

    /// The offset requested on each `getUpdates` call — proves updates are never reprocessed (FR-1).
    private(set) var getUpdatesOffsets: [Int64] = []
    private(set) var sentMessages: [(chatId: Int64, text: String, markup: ReplyMarkup)] = []
    private(set) var sentDocuments: [(chatId: Int64, filename: String, data: Data)] = []
    private(set) var registeredCommands: [BotCommand] = []

    /// The `getMe` answer: the bot username to report, or `getMeError` to throw instead (S13f
    /// connection-state probe). Defaults to a benign username.
    var botUsername: String? = "relayback_bot"
    var getMeError: Error?

    func getUpdates(offset: Int64) async throws -> [TelegramUpdate] {
        getUpdatesOffsets.append(offset)
        let index = getUpdatesOffsets.count - 1
        if index < getUpdatesScript.count {
            switch getUpdatesScript[index] {
            case let .updates(updates): return updates
            case let .failure(error): throw error
            }
        }
        // Past the script: model a long-poll with nothing to report — signal once, then block
        // until the loop is cancelled (so the run loop suspends instead of busy-spinning).
        onScriptExhausted?()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return []
    }

    func sendMessage(chatId: Int64, text: String, markup: ReplyMarkup) async throws {
        sentMessages.append((chatId, text, markup))
    }

    func sendDocument(chatId: Int64, filename: String, data: Data) async throws {
        sentDocuments.append((chatId, filename, data))
    }

    func setMyCommands(_ commands: [BotCommand]) async throws {
        registeredCommands = commands
    }

    func getMe() async throws -> TelegramBotInfo {
        if let getMeError { throw getMeError }
        return TelegramBotInfo(username: botUsername)
    }
}
