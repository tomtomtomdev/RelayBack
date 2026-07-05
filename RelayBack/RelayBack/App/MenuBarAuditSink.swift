//
//  MenuBarAuditSink.swift
//  RelayBack
//
//  S11 — the seam that makes the menu bar live. It wraps the real `AuditSink` (the file log) and,
//  on every entry, also pushes the audit line into the observable `MenuBarModel` and refreshes the
//  arm status. Auditing is the single choke point every outcome already flows through (S8), so
//  decorating it is the simplest way to keep the popover's "recent activity" and arm state current
//  without threading the UI model through the coordinator.
//
//  The row it forwards is the pure `RecentActivityRow(from:)`, built only from the audit record's
//  fields — which never contain command output or a secret (I3) — so it is safe to show in the UI.
//

import Foundation

final class MenuBarAuditSink: AuditSink {
    private let base: AuditSink
    private let menuBar: MenuBarModel

    /// Supplies the current arm status. Set after the coordinator exists (it reads coordinator
    /// state), and captured weakly there to avoid a retain cycle. Defaults to disarmed.
    var status: () -> MenuBarStatus = { MenuBarStatus(isArmed: false, remaining: 0) }

    init(base: AuditSink, menuBar: MenuBarModel) {
        self.base = base
        self.menuBar = menuBar
    }

    func append(_ entry: AuditEntry) {
        base.append(entry)
        menuBar.appendActivity(RecentActivityRow(from: entry))
        menuBar.status = status()
    }
}
