//
//  AuthGuardTests.swift
//  RelayBackTests
//
//  S3 — the arm/disarm state machine. These tests are the executable statement of invariant
//  I2 (no action runs unless the sender is allowlisted AND the session is armed) and FR-3
//  (TOTP arming, idle expiry, timer reset). The clock is injected so every time-dependent
//  case is deterministic.
//

import Foundation
import Testing
@testable import RelayBack

struct AuthGuardTests {

    // RFC 6238 seed "12345678901234567890" as raw key bytes — the secret under test.
    private let secret = Data("12345678901234567890".utf8)
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let allowed: Int64 = 111
    private let stranger: Int64 = 999
    private let idleTimeout: TimeInterval = 300

    // `RelayBack.Clock` qualified to disambiguate from the stdlib `Clock` protocol (both visible here).
    private func makeGuard(_ clock: RelayBack.Clock) -> AuthGuard {
        AuthGuard(allowlist: [allowed],
                  totpSecret: secret,
                  registry: .seed,
                  clock: clock,
                  idleTimeout: idleTimeout)
    }

    /// A currently-valid code for `date`, produced by the same TOTP oracle the guard validates against.
    private func goodCode(at date: Date) -> String { TOTP.code(secret: secret, at: date) }

    private var uptime: Action { ActionRegistry.seed.match("/uptime")! }

    // MARK: - Identity gate (I2 / FR-2)

    @Test func unknownUserRejectedForEverything() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        // Even a valid control command or a valid TOTP code from a stranger is dropped,
        // and must never arm the session.
        #expect(guardState.authorize(fromId: stranger, text: "/uptime") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/arm \(goodCode(at: clock.now))") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/status") == .rejectedUnknownUser)
        #expect(guardState.isArmed == false)
    }

    // MARK: - Disarmed blocks actions (I2)

    @Test func disarmedBlocksActions() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    // MARK: - Arming

    @Test func armWithBadCodeStaysDisarmed() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        let bad = goodCode(at: clock.now) == "000000" ? "111111" : "000000"
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(bad)") == .control(.armRejected))
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    @Test func armWithNoCodeRejected() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armRejected))
        #expect(guardState.isArmed == false)
    }

    @Test func armWithGoodCodeArmsAndActionRuns() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))") == .control(.armAccepted))
        #expect(guardState.isArmed == true)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
    }

    // MARK: - Idle expiry & timer reset (FR-3)

    @Test func armExpiresAfterIdleWindow() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: idleTimeout + 1)
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    @Test func actionResetsIdleTimer() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: 200)   // 200s < 300s window: still armed
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
        clock.advance(by: 200)   // 400s since arm, but only 200s since the action reset the timer
        // Without the reset this would have expired at 300s; with it, the session is still armed.
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
    }

    @Test func remainingArmedTimeReflectsClockAndClamps() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.remainingArmedTime == 0)                 // disarmed
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.remainingArmedTime == idleTimeout)       // just armed
        clock.advance(by: 120)
        #expect(guardState.remainingArmedTime == idleTimeout - 120)
        clock.advance(by: idleTimeout)                              // well past expiry
        #expect(guardState.remainingArmedTime == 0)                 // clamped, never negative
    }

    // MARK: - Disarm

    @Test func disarmEndsSession() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/disarm") == .control(.disarmAccepted))
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    // MARK: - Status never executes

    @Test func statusReportsAndNeverExecutes() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: false)))
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: true)))
        #expect(guardState.isArmed == true)   // status is a read; it must not change arm state
    }

    // MARK: - Unknown commands

    @Test func unknownCommandNeverRuns() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/frobnicate") == .unknownCommand)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/frobnicate") == .unknownCommand)
    }

    // MARK: - Casing

    @Test func controlTokensAreCaseInsensitive() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/ARM \(goodCode(at: clock.now))") == .control(.armAccepted))
        #expect(guardState.authorize(fromId: allowed, text: "/Status") == .control(.status(isArmed: true)))
        #expect(guardState.authorize(fromId: allowed, text: "/DisArm") == .control(.disarmAccepted))
    }
}
