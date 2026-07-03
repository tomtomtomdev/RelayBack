//
//  BackoffTests.swift
//  RelayBackTests
//
//  S11 — the pure reconnect backoff policy. Exponential growth from a base delay, doubling each
//  consecutive failure, clamped to a cap so a long outage settles into steady retries rather than
//  ballooning. No failures → no delay.
//

import Foundation
import Testing
@testable import RelayBack

struct BackoffTests {

    @Test func noFailuresMeansNoDelay() {
        #expect(Backoff().delay(afterFailures: 0) == 0)
    }

    @Test func firstFailureWaitsTheBaseDelay() {
        #expect(Backoff(base: 1, cap: 30, multiplier: 2).delay(afterFailures: 1) == 1)
    }

    @Test func delayDoublesEachConsecutiveFailure() {
        let backoff = Backoff(base: 1, cap: 30, multiplier: 2)
        #expect(backoff.delay(afterFailures: 2) == 2)
        #expect(backoff.delay(afterFailures: 3) == 4)
        #expect(backoff.delay(afterFailures: 4) == 8)
    }

    @Test func delayIsClampedToTheCap() {
        let backoff = Backoff(base: 1, cap: 30, multiplier: 2)
        // 2^9 = 512 raw → clamped to the cap, and it never exceeds it thereafter.
        #expect(backoff.delay(afterFailures: 10) == 30)
        #expect(backoff.delay(afterFailures: 100) == 30)
    }

    @Test func honorsACustomBaseAndMultiplier() {
        let backoff = Backoff(base: 2, cap: 100, multiplier: 3)
        #expect(backoff.delay(afterFailures: 1) == 2)
        #expect(backoff.delay(afterFailures: 2) == 6)
        #expect(backoff.delay(afterFailures: 3) == 18)
    }
}
