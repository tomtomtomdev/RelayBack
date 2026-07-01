//
//  TestClock.swift
//  RelayBackTests
//
//  A deterministic `Clock` fake. Time only moves when the test advances it, so idle-timeout
//  and TOTP-window behavior are fully reproducible without sleeping or touching the wall clock.
//

import Foundation
@testable import RelayBack

// `RelayBack.Clock` is qualified because the Swift standard library also exports a `Clock`
// protocol; both are visible here (imported names), so the bare name would be ambiguous.
final class TestClock: RelayBack.Clock {
    private(set) var now: Date

    init(_ start: Date) { now = start }

    func advance(by seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}
