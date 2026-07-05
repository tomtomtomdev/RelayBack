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
    /// Most-recent activity, newest last; capped so the popover never grows unbounded. Each row is
    /// a color-coded, secret-free view of one audit entry (S13c).
    private(set) var recentActivity: [RecentActivityRow]
    /// The connected bot's `@username`, shown in the "listening" row. Wired in S13f; nil until then.
    var botUsername: String?

    /// The allowlisted actions shown as read-only cards when armed (S13b). Command + description
    /// only — no runnable payload reaches the UI (invariant I1). Defaults to the seed registry.
    let actions: [ActionSummary]
    /// The most recent run, rendered in the armed popover's dark "Last result" card (S13b). The
    /// coordinator pushes this after each action completes; nil until an action has run this session.
    var lastResult: LastResultPresentation?
    /// Invoked by the armed popover's "Disarm now" button (S13b). The runtime wires it to the live
    /// coordinator's `disarm()`; defaults to a no-op so the model is usable standalone / in Previews.
    var disarm: () -> Void = {}

    /// How many recent audit lines the popover retains.
    let recentLimit: Int

    init(status: MenuBarStatus = MenuBarStatus(isArmed: false, remaining: 0),
         recentActivity: [RecentActivityRow] = [],
         botUsername: String? = nil,
         actions: [ActionSummary] = ActionRegistry.seed.actions.map(ActionSummary.init),
         lastResult: LastResultPresentation? = nil,
         recentLimit: Int = 5) {
        self.status = status
        self.botUsername = botUsername
        self.actions = actions
        self.lastResult = lastResult
        self.recentLimit = recentLimit
        self.recentActivity = Array(recentActivity.suffix(recentLimit))
    }

    /// Records one activity row, dropping the oldest beyond `recentLimit`.
    func appendActivity(_ row: RecentActivityRow) {
        recentActivity.append(row)
        if recentActivity.count > recentLimit {
            recentActivity.removeFirst(recentActivity.count - recentLimit)
        }
    }
}
