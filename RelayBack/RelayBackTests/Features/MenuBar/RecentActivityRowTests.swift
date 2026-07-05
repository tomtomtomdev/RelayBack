//
//  RecentActivityRowTests.swift
//  RelayBackTests
//
//  S13c — the pure mapping from an audit record to a color-coded RECENT row. Severity is driven
//  by the outcome: a stranger (unknown user) is the most security-relevant → danger; an authorized
//  operator blocked because the session was disarmed, or a failed arm, is a warning; ordinary runs
//  and benign events are normal. The row is built ONLY from `AuditEntry` fields — which by
//  construction (S9) carry no command output or secret — so nothing sensitive can reach the UI (I3).
//

import Foundation
import Testing
@testable import RelayBack

struct RecentActivityRowTests {

    private func entry(_ event: AuditEvent, at t: TimeInterval = 1_000_000) -> AuditEntry {
        AuditEntry(timestamp: Date(timeIntervalSince1970: t), fromId: 7, event: event)
    }

    @Test func successfulRunIsNormalWithOkStatus() {
        let row = RecentActivityRow(from: entry(.actionRan(command: "/uptime", exitCode: 0)))
        #expect(row.command == "/uptime")
        #expect(row.statusText == "ok")
        #expect(row.severity == .normal)
    }

    @Test func failedRunIsDangerWithExitStatus() {
        let row = RecentActivityRow(from: entry(.actionRan(command: "/disk", exitCode: 1)))
        #expect(row.command == "/disk")
        #expect(row.statusText == "exit 1")
        #expect(row.severity == .danger)
    }

    @Test func unknownUserRejectionIsDanger() {
        let row = RecentActivityRow(from: entry(.rejected(reason: "unknown user")))
        #expect(row.command == "rejected")
        #expect(row.statusText == "unknown user")
        #expect(row.severity == .danger)
    }

    @Test func disarmedRejectionIsWarning() {
        let row = RecentActivityRow(from: entry(.rejected(reason: "disarmed")))
        #expect(row.statusText == "disarmed")
        #expect(row.severity == .warning)
    }

    @Test func badCodeRejectionIsWarning() {
        let row = RecentActivityRow(from: entry(.rejected(reason: "bad code")))
        #expect(row.severity == .warning)
    }

    @Test func unknownCommandRejectionIsNormal() {
        let row = RecentActivityRow(from: entry(.rejected(reason: "unknown command")))
        #expect(row.statusText == "unknown command")
        #expect(row.severity == .normal)
    }

    @Test func controlEventIsNormal() {
        let row = RecentActivityRow(from: entry(.control("armed")))
        #expect(row.command == "armed")
        #expect(row.statusText == "")
        #expect(row.severity == .normal)
    }

    @Test func timeIsFormattedHHmmInUTC() {
        // 1_000_000s after the epoch is 1970-01-12 13:46:40 UTC — the RECENT time mirrors the
        // audit log's UTC clock so it is deterministic and greppable against the log.
        let row = RecentActivityRow(from: entry(.control("armed")))
        #expect(row.time == "13:46")
    }

    @Test func rowCarriesNoOutputOrSecret() {
        // I3 at the UI edge: a run's row is derived solely from the command token + exit code —
        // `AuditEntry` has no field that can hold stdout/stderr or a secret, so none can leak here.
        let row = RecentActivityRow(from: entry(.actionRan(command: "/whoami", exitCode: 0)))
        #expect(row.command == "/whoami")
        #expect(row.statusText == "ok")            // not the process output
    }
}
