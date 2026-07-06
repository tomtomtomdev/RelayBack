//
//  ArmingConfigPresentationTests.swift
//  RelayBackTests
//
//  S13d — the Security pane's "Idle timeout" / "Drift tolerance" rows are DISPLAY-ONLY: they show
//  the app's fixed arming config (SPEC pins the TOTP config; AuthGuard uses 300s idle, ±1 drift).
//  This pure formatter turns those constants into the pill text + drift subtitle the pane renders.
//

import Foundation
import Testing
@testable import RelayBack

struct ArmingConfigPresentationTests {

    @Test func formatsTheIdleTimeoutAsMinutesSeconds() {
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 1).idleTimeoutText == "5:00")
        #expect(ArmingConfigPresentation(idleTimeout: 90, driftSteps: 1).idleTimeoutText == "1:30")
        #expect(ArmingConfigPresentation(idleTimeout: 5, driftSteps: 1).idleTimeoutText == "0:05")
    }

    @Test func driftIsEnabledWhenAtLeastOneStepIsAccepted() {
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 1).driftIsEnabled)
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 2).driftIsEnabled)
        #expect(!ArmingConfigPresentation(idleTimeout: 300, driftSteps: 0).driftIsEnabled)
    }

    @Test func describesTheDriftToleranceForTheOperator() {
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 1).driftSubtitle
                == "Accept ±1 time step (RFC 6238)")
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 2).driftSubtitle
                == "Accept ±2 time steps (RFC 6238)")
        #expect(ArmingConfigPresentation(idleTimeout: 300, driftSteps: 0).driftSubtitle
                == "Exact codes only (no drift)")
    }
}
