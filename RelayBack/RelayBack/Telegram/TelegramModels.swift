//
//  TelegramModels.swift
//  RelayBack
//
//  S6 — the Telegram Bot API wire types and the pure logic over them (FR-1).
//
//  These decode the `getUpdates` response. We model only the fields the app consumes — `from.id`
//  (identity gate, invariant I2), `chat.id` (where to reply), `text` (the command), and
//  `update_id` (offset advance). Unknown keys are ignored by `Decodable`, so a minimal model
//  still decodes real payloads. Optionals mirror the API: an update need not carry a `message`
//  (edited messages, callback queries, …), and a message need not carry a `from` (channel posts).
//
//  Everything here is pure — no URLSession. The thin networking client lives in `TelegramClient`.
//

import Foundation

/// One entry from `getUpdates`. `message` is nil for update kinds we don't handle.
struct TelegramUpdate: Decodable, Equatable {
    let updateId: Int64
    let message: TelegramMessage?
}

/// A chat message. `from` is nil when the sender is not a user (e.g. a channel post); such a
/// message can never be authorized, since the allowlist matches on `from.id`.
struct TelegramMessage: Decodable, Equatable {
    let from: TelegramUser?
    let chat: TelegramChat
    let text: String?
}

/// The sender. Only `id` is consumed — it is the value checked against the allowlist (I2, FR-2).
struct TelegramUser: Decodable, Equatable {
    let id: Int64
}

/// The conversation a message belongs to. `id` is where replies are sent (never used for auth).
struct TelegramChat: Decodable, Equatable {
    let id: Int64
}

/// The `getMe` result — only the bot's `@username` is consumed, to show the live connection state
/// (S13f). A separate type from `TelegramUser` so the identity gate (`from.id`) stays untouched.
struct TelegramBotInfo: Decodable, Equatable {
    let username: String?
}

extension TelegramUpdate {
    /// The `getUpdates` envelope: `{ "ok": true, "result": [ <update>, … ] }`.
    private struct Batch: Decodable {
        let result: [TelegramUpdate]
    }

    /// Decodes a `getUpdates` response body into its updates. Snake_case keys (`update_id`, …)
    /// are mapped automatically. Throws on malformed JSON — it never traps (FR-1: survive bad
    /// input). Unknown update kinds decode with `message == nil` rather than failing the batch.
    static func decodeBatch(from data: Data) throws -> [TelegramUpdate] {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(Batch.self, from: data).result
    }

    /// The offset to request next so no update is ever reprocessed (FR-1): one past the highest
    /// `update_id` seen. An empty batch, or a stale batch entirely below `current`, leaves the
    /// offset unchanged — polling never rewinds.
    static func nextOffset(after current: Int64, in updates: [TelegramUpdate]) -> Int64 {
        guard let maxId = updates.map(\.updateId).max() else { return current }
        return max(current, maxId + 1)
    }
}
