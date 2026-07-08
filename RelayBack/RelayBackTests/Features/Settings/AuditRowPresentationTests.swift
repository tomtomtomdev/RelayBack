//
//  AuditRowPresentationTests.swift
//  RelayBackTests
//
//  S13f — the pure mapping from an audit record to one row of the Settings Audit pane (columns
//  Time · from.id · Action/decision · Exit, color-coded by decision/exit). Like the popover's
//  RECENT row (S13c), it is built ONLY from `AuditEntry` fields — which by construction (S9) carry
//  no command output or secret — so no secret/full-output column can exist (invariant I3).
//
//  Colors follow the handoff's Audit table:
//    • a run shows its command (accent blue) + a green/red exit code;
//    • a control event (armed/disarmed/status) is green with an em-dash exit;
//    • a rejection is amber (disarmed / failed arm) or red (unknown user), tinting the whole row.
//

import Foundation
import Testing
@testable import RelayBack

struct AuditRowPresentationTests {

    private func entry(_ event: AuditEvent, at t: TimeInterval = 1_000_000, from: Int64 = 481920774) -> AuditEntry {
        AuditEntry(timestamp: Date(timeIntervalSince1970: t), fromId: from, event: event)
    }

    // MARK: - Runs

    @Test func successfulRunShowsBlueCommandAndGreenExit() {
        let row = AuditRowPresentation(from: entry(.actionRan(command: "/uptime", exitCode: 0)))
        #expect(row.fromIdText == "481920774")
        #expect(row.action == "/uptime")
        #expect(row.actionRole == .command)
        #expect(row.exitText == "0")
        #expect(row.exitIsSuccess == true)
        #expect(row.severity == .normal)
    }

    @Test func failedRunShowsExitCodeAndIsDanger() {
        let row = AuditRowPresentation(from: entry(.actionRan(command: "/disk", exitCode: 1)))
        #expect(row.action == "/disk")
        #expect(row.exitText == "1")
        #expect(row.exitIsSuccess == false)
        #expect(row.severity == .danger)
    }

    // MARK: - Control events

    @Test func controlEventIsGreenWithEmDashExit() {
        let row = AuditRowPresentation(from: entry(.control("armed")))
        #expect(row.action == "armed")
        #expect(row.actionRole == .control)
        #expect(row.exitText == "—")
        #expect(row.exitIsSuccess == nil)
        #expect(row.severity == .normal)
    }

    // MARK: - Rejections

    @Test func disarmedRejectionIsWarning() {
        let row = AuditRowPresentation(from: entry(.rejected(reason: "disarmed")))
        #expect(row.action == "rejected · disarmed")
        #expect(row.actionRole == .rejected)
        #expect(row.exitText == "—")
        #expect(row.severity == .warning)
    }

    @Test func unknownUserRejectionIsDanger() {
        let row = AuditRowPresentation(from: entry(.rejected(reason: "unknown user")))
        #expect(row.action == "rejected · unknown user")
        #expect(row.severity == .danger)
    }

    // MARK: - Ordering + I3

    @Test func rowsAreNewestFirstWithStableIds() {
        let entries = [
            entry(.control("armed"), at: 1_000),
            entry(.actionRan(command: "/uptime", exitCode: 0), at: 2_000),
            entry(.rejected(reason: "unknown user"), at: 3_000),
        ]
        let rows = AuditRowPresentation.rows(from: entries)
        #expect(rows.count == 3)
        #expect(rows[0].action == "rejected · unknown user")  // newest first
        #expect(rows[2].action == "armed")                    // oldest last
        #expect(Set(rows.map(\.id)).count == 3)               // ids unique (zebra + ForEach)
    }

    @Test func noFieldCanCarryOutputOrSecret() {
        // The entry never holds output/secrets (S9); assert the row never surfaces one either.
        let secret = "123456:AA-super-secret-bot-token"
        let row = AuditRowPresentation(from: entry(.actionRan(command: "/whoami", exitCode: 0)))
        let allText = [row.time, row.fromIdText, row.action, row.exitText].joined(separator: " ")
        #expect(!allText.contains(secret))
        #expect(!allText.contains("super-secret"))
    }
}
