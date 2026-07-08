//
//  AuditRowPresentation.swift
//  RelayBack
//
//  S13f — the pure mapping from an `AuditEntry` to one row of the Settings Audit pane (columns
//  Time · from.id · Action/decision · Exit, color-coded by decision/exit — the handoff's Audit
//  table). Like the popover's RECENT row (S13c) it is built ONLY from the audit record's fields,
//  which by construction (S9) carry no command output or secret — so nothing sensitive can reach
//  the table (invariant I3), the same guarantee the audit log itself has.
//
//  A run shows its command (accent blue via `.command`) and a green/red exit code; a control event
//  (armed/disarmed/status) is green (`.control`) with an em-dash exit; a rejection reads
//  "rejected · <reason>" and is amber (disarmed / failed arm) or red (unknown user), tinting the row.
//

import Foundation

struct AuditRowPresentation: Identifiable, Equatable {
    /// Drives the row tint and the rejected/exit text color.
    enum Severity: Equatable {
        case normal   // runs, control events — no row tint
        case warning  // authorized-but-blocked (disarmed) / failed arm — amber tint
        case danger   // unauthorized sender, or a non-zero exit — red tint
    }

    /// The color role of the middle "Action / decision" column: a command is accent blue, a control
    /// event is green, a rejection follows its severity.
    enum ActionRole: Equatable { case command, control, rejected }

    let id: Int
    let time: String            // HH:mm, UTC — mirrors the audit log's clock
    let fromIdText: String
    let action: String          // middle column text
    let actionRole: ActionRole
    let exitText: String        // "0" / "1" / "—"
    let exitIsSuccess: Bool?    // true = green, false = red, nil = grey (em-dash)
    let severity: Severity

    init(from entry: AuditEntry, id: Int = 0) {
        self.id = id
        self.time = Self.timeFormatter.string(from: entry.timestamp)
        self.fromIdText = String(entry.fromId)

        switch entry.event {
        case let .actionRan(command, exitCode):
            self.action = command
            self.actionRole = .command
            self.exitText = String(exitCode)
            self.exitIsSuccess = exitCode == 0
            self.severity = exitCode == 0 ? .normal : .danger

        case let .control(text):
            self.action = text
            self.actionRole = .control
            self.exitText = "—"
            self.exitIsSuccess = nil
            self.severity = .normal

        case let .rejected(reason):
            self.action = "rejected · \(reason)"
            self.actionRole = .rejected
            self.exitText = "—"
            self.exitIsSuccess = nil
            self.severity = Self.severity(forRejection: reason)
        }
    }

    /// Maps a batch of chronological entries (as read from the log) to newest-first rows with
    /// stable, unique ids for zebra striping and `ForEach`.
    static func rows(from entries: [AuditEntry]) -> [AuditRowPresentation] {
        entries.reversed().enumerated().map { index, entry in
            AuditRowPresentation(from: entry, id: index)
        }
    }

    /// Same severity buckets as the popover's RECENT list (S13c): an unauthorized stranger is the
    /// most security-relevant → danger; a disarmed block or a failed arm → warning; else benign.
    private static func severity(forRejection reason: String) -> Severity {
        let r = reason.lowercased()
        if r.contains("unknown user") || r.contains("unauthorized") { return .danger }
        if r.contains("disarm") || r.contains("code") { return .warning }
        return .normal
    }

    /// UTC `HH:mm`, matching `LogText`'s UTC audit timestamps so the pane time lines up with the
    /// log and stays deterministic under test (independent of the machine's time zone).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()
}
