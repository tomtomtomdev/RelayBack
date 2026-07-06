//
//  ArmingConfigPresentation.swift
//  RelayBack
//
//  S13d — the Security pane's "Idle timeout" and "Drift tolerance" rows. These are DISPLAY-ONLY:
//  SPEC pins the TOTP config fixed (`TOTP`/`OtpAuthURI`) and `AuthGuard` uses a fixed 300s idle
//  window + ±1 drift, so the rows reflect the real configured constants rather than editing them.
//  Making them editable would require a deliberate SPEC change (SPEC §9). Pure so it's unit-tested;
//  the `m:ss` formatting reuses `MenuBarStatus.clockString` to stay consistent with the popover.
//

import Foundation

struct ArmingConfigPresentation: Equatable {
    /// The armed-session idle window, in seconds (AuthGuard's `idleTimeout`).
    let idleTimeout: TimeInterval
    /// Number of ±TOTP steps accepted on either side of the current window (TOTP `driftSteps`).
    let driftSteps: Int

    /// The idle-timeout pill text, e.g. `5:00`.
    var idleTimeoutText: String { MenuBarStatus.clockString(idleTimeout) }

    /// Whether any clock drift is tolerated (drives the row's toggle appearance).
    var driftIsEnabled: Bool { driftSteps >= 1 }

    /// Human-readable description of the accepted drift, matching the handoff subtitle.
    var driftSubtitle: String {
        guard driftIsEnabled else { return "Exact codes only (no drift)" }
        let unit = driftSteps == 1 ? "step" : "steps"
        return "Accept ±\(driftSteps) time \(unit) (RFC 6238)"
    }
}
