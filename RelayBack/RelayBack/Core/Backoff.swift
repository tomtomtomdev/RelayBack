//
//  Backoff.swift
//  RelayBack
//
//  S11 — the pure reconnect backoff policy for the polling loop. When the Telegram transport
//  fails (a network blip, the Mac waking from sleep), the loop waits before retrying, doubling the
//  wait each consecutive failure up to a cap so a long outage settles into steady retries instead
//  of hammering the network. A successful poll resets the failure count (owned by the caller).
//
//  Pure and framework-light — no timers, no I/O — so the delay schedule is unit-tested directly.
//

import Foundation

struct Backoff {
    /// Delay after the first failure, in seconds.
    let base: TimeInterval
    /// Upper bound the delay is clamped to, in seconds.
    let cap: TimeInterval
    /// Growth factor applied per additional consecutive failure.
    let multiplier: Double

    init(base: TimeInterval = 1, cap: TimeInterval = 30, multiplier: Double = 2) {
        self.base = base
        self.cap = cap
        self.multiplier = multiplier
    }

    /// The delay to wait given `failures` consecutive failures (1 = the first failure). Zero
    /// failures means a successful poll — no delay. The result is clamped to `cap`.
    func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let raw = base * pow(multiplier, Double(failures - 1))
        return min(raw, cap)
    }
}
