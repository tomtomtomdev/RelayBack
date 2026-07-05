//
//  RecentActivityRow.swift
//  RelayBack
//
//  S13c — the pure mapping from an `AuditEntry` to one color-coded row in the popover's RECENT
//  list (a time, a command/label, a status phrase, and a severity). It is built ONLY from the
//  audit record's fields, which by construction (S9) carry no command output or secret — so
//  nothing sensitive can reach the UI (invariant I3), the same guarantee the audit log itself has.
//
//  Severity follows the outcome's security weight, per the design handoff's RECENT colors:
//    • danger  (red)   — an unauthorized sender (unknown user), or an action that exited non-zero.
//    • warning (amber)  — an authorized operator blocked because disarmed, or a failed arm.
//    • normal          — successful runs, benign control events, and other rejections.
//
//  NOTE: `AuditEvent.rejected` carries only the reason, not the offending command token, so a
//  rejection row's command column reads "rejected" and the reason is the status. Surfacing the
//  rejected command would mean widening the audit model (S9) — deliberately out of this UI slice.
//

import Foundation

struct RecentActivityRow: Equatable {
    enum Severity: Equatable {
        case normal   // successful runs, control events, benign rejections — default color
        case warning  // authorized-but-blocked (disarmed) / failed arm — amber
        case danger   // unauthorized sender, or a non-zero exit — red
    }

    let time: String        // HH:mm, UTC — mirrors the audit log's clock (deterministic, greppable)
    let command: String     // left mono label: the /command for a run, else a short category
    let statusText: String  // right-aligned status: "ok" / "exit N" / a rejection reason
    let severity: Severity

    init(from entry: AuditEntry) {
        self.time = Self.timeFormatter.string(from: entry.timestamp)

        switch entry.event {
        case let .actionRan(command, exitCode):
            self.command = command
            self.statusText = exitCode == 0 ? "ok" : "exit \(exitCode)"
            self.severity = exitCode == 0 ? .normal : .danger

        case let .control(text):
            self.command = text
            self.statusText = ""
            self.severity = .normal

        case let .rejected(reason):
            self.command = "rejected"
            self.statusText = reason
            self.severity = Self.severity(forRejection: reason)
        }
    }

    /// Maps a rejection reason to a severity. Matches the short, secret-free phrases the coordinator
    /// (S8) emits: an unauthorized stranger is the most security-relevant; a disarmed block or a
    /// failed arm is a warning; anything else (e.g. an unknown command from a valid operator) is
    /// benign. Matched by substring so a lightly-reworded reason still lands in the right bucket.
    private static func severity(forRejection reason: String) -> Severity {
        let r = reason.lowercased()
        if r.contains("unknown user") || r.contains("unauthorized") { return .danger }
        if r.contains("disarm") || r.contains("code") { return .warning }
        return .normal
    }

    /// UTC `HH:mm`, matching `LogText`'s UTC audit timestamps so the popover time lines up with the
    /// log and stays deterministic under test (independent of the machine's time zone).
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "HH:mm"
        return f
    }()
}
