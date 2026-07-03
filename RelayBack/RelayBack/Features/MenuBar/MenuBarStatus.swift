//
//  MenuBarStatus.swift
//  RelayBack
//
//  S10 — the pure mapping from arm state to the strings the menu-bar popover shows (FR-9). Kept a
//  plain value type (no SwiftUI) so the state→text mapping and the countdown formatting are unit
//  tested directly; the SwiftUI `MenuBarRootView` just renders these. The live arm state is fed in
//  by the run loop in S11 (from `AuthGuard.isArmed` / `remainingArmedTime`).
//

import Foundation

struct MenuBarStatus: Equatable {
    let isArmed: Bool
    /// Seconds left in the armed window (only meaningful when `isArmed`).
    let remaining: TimeInterval

    /// The one-word state shown prominently in the popover.
    var headline: String { isArmed ? "Armed" : "Disarmed" }

    /// The supporting line: a live countdown while armed, or how to arm while disarmed.
    var detail: String {
        isArmed
            ? "\(Self.clockString(remaining)) remaining"
            : "Send /arm <code> from Telegram to start."
    }

    /// Formats a duration as `m:ss`, clamped to `0:00` (never negative).
    static func clockString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
