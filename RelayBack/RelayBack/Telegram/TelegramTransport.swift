//
//  TelegramTransport.swift
//  RelayBack
//
//  S6 — the seam between the app and the Telegram Bot API (FR-1, FR-6). Every network call the
//  app makes goes through this protocol, so `AppCoordinator` (S8) and the polling loop (S11) are
//  unit-testable against a fake — no live network in tests. The real implementation is
//  `TelegramClient`; a test double will accompany the slices that exercise it.
//
//  The methods mirror the Bot API endpoints the app needs. They take primitives (chat id, text,
//  file data) rather than `OutgoingMessage`; the coordinator bridges `OutputFormatter` output to
//  these calls, keeping this protocol a thin, faithful mirror of the wire API.
//

import Foundation

/// A command advertised via `setMyCommands` so it autocompletes in the Telegram client (SPEC §5).
/// `command` is the bare name without the leading slash, per the Bot API.
struct BotCommand: Encodable, Equatable {
    let command: String
    let description: String
}

/// The Bot API `reply_markup` attached to an outgoing message. Modelled as a closed set so the
/// coordinator picks an intent and the transport owns the wire shape:
///   • `.none` — an ordinary reply, no markup.
///   • `.forceReply` — `force_reply`, so the client opens the keyboard for a free-text answer
///     (used to prompt for the TOTP code after a code-less `/arm`, S20).
///   • `.keyboard(buttons)` — a one-time custom reply keyboard, one tappable button per string,
///     so the operator picks from options instead of typing (the `/cd` repo picker, S25). The
///     button labels are the only thing disclosed — keep them free of secrets/paths (I3).
enum ReplyMarkup: Equatable {
    case none
    case forceReply
    case keyboard([String])
}

protocol TelegramTransport {
    /// Long-poll for updates with `update_id >= offset`, returning the decoded batch (may be
    /// empty). The offset advances past processed updates so none is reprocessed (FR-1).
    func getUpdates(offset: Int64) async throws -> [TelegramUpdate]

    /// Send a text reply to `chatId` (already chunked ≤ 4096 chars by `OutputFormatter`), with the
    /// given `reply_markup` (`.none` for an ordinary reply). See the `sendMessage(chatId:text:)`
    /// and `sendMessage(chatId:text:forceReply:)` convenience overloads below.
    func sendMessage(chatId: Int64, text: String, markup: ReplyMarkup) async throws

    /// Send `data` as a file attachment to `chatId` — used for oversized command output (FR-6).
    func sendDocument(chatId: Int64, filename: String, data: Data) async throws

    /// Register the allowlisted action commands so they autocomplete in chat.
    func setMyCommands(_ commands: [BotCommand]) async throws

    /// Identify the bot behind the token — used to show the live connection state / `@username`
    /// (S13f). A successful call also confirms the transport can reach Telegram.
    func getMe() async throws -> TelegramBotInfo
}

extension TelegramTransport {
    /// Convenience for the common case: an ordinary reply with no reply-keyboard markup.
    func sendMessage(chatId: Int64, text: String) async throws {
        try await sendMessage(chatId: chatId, text: text, markup: .none)
    }

    /// Convenience for the S20 arm prompt: `force_reply` when `forceReply`, otherwise no markup.
    func sendMessage(chatId: Int64, text: String, forceReply: Bool) async throws {
        try await sendMessage(chatId: chatId, text: text, markup: forceReply ? .forceReply : .none)
    }
}
