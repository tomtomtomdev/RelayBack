//
//  Clock.swift
//  RelayBack
//
//  S3 — the one source of "now" for time-dependent logic (AuthGuard idle expiry, TOTP
//  windows). Injecting it keeps that logic deterministic under test: the fake advances time
//  explicitly, so nothing sleeps or reads the wall clock.
//
//  Note: this is RelayBack's own minimal time source, intentionally distinct from the Swift
//  standard library `Clock` protocol (which models durations/sleeping). Same-module lookup
//  resolves unqualified `Clock` to this type.
//

import Foundation

protocol Clock {
    var now: Date { get }
}

/// Production clock: the real wall clock. Not unit-tested (tests inject `TestClock`).
struct SystemClock: Clock {
    var now: Date { Date() }
}
