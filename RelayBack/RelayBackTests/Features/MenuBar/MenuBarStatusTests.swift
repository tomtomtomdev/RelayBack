//
//  MenuBarStatusTests.swift
//  RelayBackTests
//
//  S10 — the pure arm-state → popover-text mapping and the m:ss countdown formatting (FR-9).
//

import Foundation
import Testing
@testable import RelayBack

struct MenuBarStatusTests {

    @Test func disarmedShowsStateAndHowToArm() {
        let status = MenuBarStatus(isArmed: false, remaining: 0)
        #expect(status.headline == "Disarmed")
        #expect(status.detail.contains("/arm"))
    }

    @Test func armedShowsCountdown() {
        let status = MenuBarStatus(isArmed: true, remaining: 272)
        #expect(status.headline == "Armed")
        #expect(status.detail == "4:32 remaining")
    }

    @Test func clockStringFormatsAsMinutesSeconds() {
        #expect(MenuBarStatus.clockString(0) == "0:00")
        #expect(MenuBarStatus.clockString(5) == "0:05")
        #expect(MenuBarStatus.clockString(60) == "1:00")
        #expect(MenuBarStatus.clockString(272) == "4:32")
        #expect(MenuBarStatus.clockString(599) == "9:59")
    }

    @Test func clockStringClampsNegativeToZero() {
        #expect(MenuBarStatus.clockString(-10) == "0:00")
    }
}
