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
    /// Which color treatment the header status pill uses; the view maps this to the tokens.
    enum PillStyle: Equatable { case armed, disarmed }

    let isArmed: Bool
    /// Seconds left in the armed window (only meaningful when `isArmed`).
    let remaining: TimeInterval

    /// The one-word state shown prominently in the popover.
    var headline: String { isArmed ? "Armed" : "Disarmed" }

    /// Uppercased text inside the header status pill (matches the handoff).
    var pillLabel: String { isArmed ? "ARMED" : "DISARMED" }

    /// The pill's color treatment: green when armed, grey when disarmed.
    var pillStyle: PillStyle { isArmed ? .armed : .disarmed }

    /// Whether to render the `m:ss` countdown chip beside the pill (armed only).
    var showsCountdown: Bool { isArmed }

    /// The countdown chip's `m:ss` text (only meaningful when `showsCountdown`).
    var countdown: String { Self.clockString(remaining) }

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
