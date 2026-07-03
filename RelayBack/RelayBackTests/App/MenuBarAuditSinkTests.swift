//
//  MenuBarAuditSinkTests.swift
//  RelayBackTests
//
//  S11 — the audit-sink decorator that also feeds the menu bar. It must forward every entry to the
//  wrapped sink (so the file log is unaffected) and mirror it into the live `MenuBarModel`: append
//  the (already sanitized, secret-free) audit line and refresh the arm status.
//

import Foundation
import Testing
@testable import RelayBack

struct MenuBarAuditSinkTests {

    @Test func forwardsToBaseAndUpdatesMenuBar() {
        let base = InMemoryAuditSink()
        let menuBar = MenuBarModel()
        let sink = MenuBarAuditSink(base: base, menuBar: menuBar)
        sink.status = { MenuBarStatus(isArmed: true, remaining: 42) }

        let entry = AuditEntry(timestamp: Date(timeIntervalSince1970: 1_000_000),
                               fromId: 7,
                               event: .control("armed"))
        sink.append(entry)

        #expect(base.entries.map(\.line) == [entry.line])   // file log still gets the entry
        #expect(menuBar.recentAudit == [entry.line])         // and the popover shows it
        #expect(menuBar.status == MenuBarStatus(isArmed: true, remaining: 42))
    }
}
