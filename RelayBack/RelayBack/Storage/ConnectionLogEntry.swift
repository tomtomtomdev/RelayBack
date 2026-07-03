//
//  ConnectionLogEntry.swift
//  RelayBack
//
//  The connection-lifecycle log: a persistent, append-only record of the poll loop's transport
//  health, kept separate from the command audit log (which is scoped to received commands, FR-8).
//  The poll loop logs only *transitions* — reaching Telegram (`connected`) and losing it
//  (`disconnected`) — so a healthy loop doesn't spam the file and an outage leaves one clear line.
//
//  Invariant I3: a `ConnectionLogEntry` can carry only a timestamp, the event, and — for a
//  disconnect — a short reason produced by `ConnectionReason.from`, which is derived from the error
//  type/code only and NEVER from its description (a transport error can carry the token-bearing
//  request URL). Free text is still sanitized so one transition yields exactly one line.
//

import Foundation

/// A transport-health transition the poll loop observed.
enum ConnectionEvent: Equatable {
    /// The loop reached the Telegram transport — at startup, or recovering after an outage.
    case connected
    /// A poll failed. `reason` is short and secret-free (see `ConnectionReason.from`).
    case disconnected(reason: String)
}

struct ConnectionLogEntry: Equatable {
    let timestamp: Date
    let event: ConnectionEvent

    /// The one-line, append-only rendering: `<ISO8601-UTC> connection=<detail>`.
    var line: String {
        "\(LogText.timestamp(timestamp)) connection=\(detail)"
    }

    private var detail: String {
        switch event {
        case .connected:
            return "connected"
        case let .disconnected(reason):
            return #"disconnected reason="\#(LogText.sanitized(reason))""#
        }
    }
}

/// Maps a transport error to a SHORT, secret-free disconnect reason. Deliberately reduces to the
/// error's type/code only — it never interpolates the error's description, because a URLError can
/// carry the failing request URL (which embeds the bot token in its path) in its userInfo (I3).
enum ConnectionReason {
    static func from(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "network error \(urlError.code.rawValue)"
        }
        return "transport error"
    }
}

/// The append-only connection-log seam. `FileConnectionLog` is the real backing. Non-throwing by
/// design — logging is best-effort and must never break the poll loop.
protocol ConnectionSink {
    func append(_ entry: ConnectionLogEntry)
}
