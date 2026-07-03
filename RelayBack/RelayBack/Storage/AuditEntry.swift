//
//  AuditEntry.swift
//  RelayBack
//
//  S9 — the audit record and the sink it flows into (FR-8, invariant I3).
//
//  An `AuditEntry` is a pure value type describing one received command: when, from whom, and
//  the decision the app reached. Its `line` is the single-line, human-readable rendering that
//  gets appended to the log — the TDD'd surface. By construction the entry carries only the
//  fields SPEC §4.6 allows (timestamp, `from.id`, matched action + exit code, or a rejection
//  reason) and NEVER command output or a secret (I3). Free text is sanitized so one received
//  command can only ever produce one line — an attacker can't inject extra audit lines.
//
//  `AuditSink` is the seam the coordinator (S8) writes through; the real append-only file
//  implementation is `FileAuditLog`. Kept non-throwing: auditing is best-effort background
//  bookkeeping and must never break command handling — the file sink handles its own I/O
//  errors internally.
//

import Foundation

/// What happened to one received command. Deliberately narrow: it can express an action that
/// ran (command token + exit code only), a session-control outcome, or a rejection — and it has
/// no field capable of holding command output or a secret (invariant I3).
enum AuditEvent: Equatable {
    /// An allowlisted, armed action ran. Records only the command token and exit code.
    case actionRan(command: String, exitCode: Int32)
    /// A session-control command changed or reported state (e.g. "armed", "disarmed", "status").
    case control(String)
    /// A received command was not run. `reason` is a short, secret-free phrase
    /// (e.g. "unknown user", "disarmed", "bad code", "unknown command").
    case rejected(reason: String)
}

struct AuditEntry: Equatable {
    let timestamp: Date
    let fromId: Int64
    let event: AuditEvent

    /// The one-line, append-only rendering: `<ISO8601-UTC> from=<id> <detail>`. Timestamp and
    /// free-text sanitizing are shared with the connection log via `LogText`.
    var line: String {
        "\(LogText.timestamp(timestamp)) from=\(fromId) \(detail)"
    }

    private var detail: String {
        switch event {
        case let .actionRan(command, exitCode):
            return "action=\(LogText.sanitized(command)) exit=\(exitCode)"
        case let .control(text):
            return #"control="\#(LogText.sanitized(text))""#
        case let .rejected(reason):
            return #"rejected="\#(LogText.sanitized(reason))""#
        }
    }
}

/// The append-only audit seam. The coordinator (S8) hands every received command's outcome to a
/// sink; `FileAuditLog` is the real backing. Non-throwing by design — logging is best-effort.
protocol AuditSink {
    func append(_ entry: AuditEntry)
}
