//
//  MenuBarModel.swift
//  RelayBack
//
//  S10 — the @Observable view state behind the menu-bar popover (FR-9): current arm status plus a
//  short tail of recent audit lines. It holds no I/O; the S11 run loop pushes live values in as it
//  polls (arm state from `AuthGuard`, recent lines as they're appended to the audit log). The
//  status→text mapping lives in the pure `MenuBarStatus`, so this stays a thin container.
//

import Foundation

@Observable
final class MenuBarModel {
    /// Current arm status, as rendered by the popover.
    var status: MenuBarStatus
    /// Most-recent audit lines, newest last; capped so the popover never grows unbounded.
    private(set) var recentAudit: [String]

    /// How many recent audit lines the popover retains.
    let recentLimit: Int

    init(status: MenuBarStatus = MenuBarStatus(isArmed: false, remaining: 0),
         recentAudit: [String] = [],
         recentLimit: Int = 5) {
        self.status = status
        self.recentLimit = recentLimit
        self.recentAudit = Array(recentAudit.suffix(recentLimit))
    }

    /// Records one audit line, dropping the oldest beyond `recentLimit`.
    func appendAudit(_ line: String) {
        recentAudit.append(line)
        if recentAudit.count > recentLimit {
            recentAudit.removeFirst(recentAudit.count - recentLimit)
        }
    }
}
