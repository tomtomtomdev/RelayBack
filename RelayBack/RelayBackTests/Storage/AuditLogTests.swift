//
//  AuditLogTests.swift
//  RelayBackTests
//
//  S9 — the audit-log contract (FR-8, invariant I3). Two surfaces are exercised here:
//
//  1. `AuditEntry.line` — the PURE, one-line-per-command formatting. This is the TDD'd core:
//     it must render timestamp + from.id + the decision (action+exit, control, or rejection)
//     and NOTHING else — no secrets, no command output. Newlines in free text are neutralized
//     so one received command can only ever produce one audit line (append-only integrity, I3).
//  2. `FileAuditLog` — the real append-only file sink, verified by a focused temp-file smoke
//     test (safe, isolated I/O — no real Keychain, no network, no persistent side effects):
//     appends round-trip through the pure formatter and never clobber earlier lines (FR-8).
//

import Foundation
import Testing
@testable import RelayBack

struct AuditLogTests {

    /// A fixed, deterministic instant: 2026-07-03T15:04:05Z. Built without the formatter under
    /// test, so the timestamp assertions are not circular.
    private static func fixedTimestamp() -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 7
        components.day = 3
        components.hour = 15
        components.minute = 4
        components.second = 5
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    // MARK: - Pure line formatting

    @Test func actionRanLineHasTimestampFromIdCommandAndExit() {
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 123456789,
            event: .actionRan(command: "/uptime", exitCode: 0)
        )
        #expect(entry.line == "2026-07-03T15:04:05Z from=123456789 action=/uptime exit=0")
    }

    @Test func nonzeroExitCodeIsRecorded() {
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 42,
            event: .actionRan(command: "/disk", exitCode: 1)
        )
        #expect(entry.line == "2026-07-03T15:04:05Z from=42 action=/disk exit=1")
    }

    @Test func rejectedLineShowsReason() {
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 999,
            event: .rejected(reason: "unknown user")
        )
        #expect(entry.line == #"2026-07-03T15:04:05Z from=999 rejected="unknown user""#)
    }

    @Test func controlLineShowsDetail() {
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 7,
            event: .control("armed")
        )
        #expect(entry.line == #"2026-07-03T15:04:05Z from=7 control="armed""#)
    }

    // MARK: - Invariant I3 / append-only integrity

    @Test func freeTextNewlinesAreNeutralizedToKeepOneLinePerEntry() {
        // A reason (or any free text) that smuggles in newlines must not split one received
        // command into multiple audit lines — that would corrupt the append-only record.
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 1,
            event: .rejected(reason: "unknown command\n2026-01-01T00:00:00Z from=0 action=/evil exit=0")
        )
        #expect(!entry.line.contains("\n"))
        #expect(!entry.line.contains("\r"))
    }

    @Test func embeddedQuotesInFreeTextCannotBreakOutOfTheQuotedField() {
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 1,
            event: .control(#"weird"quote"#)
        )
        // Exactly one pair of delimiter quotes; the inner quote is neutralized.
        #expect(entry.line.filter { $0 == "\"" }.count == 2)
    }

    @Test func actionEntryCarriesNoOutputOrSecret() {
        // `actionRan` records only the command token and exit code — never stdout/stderr — so a
        // secret appearing in command output can never reach the audit log (invariant I3).
        let secret = "123456:AA-super-secret-bot-token"
        let entry = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 5,
            event: .actionRan(command: "/whoami", exitCode: 0)
        )
        #expect(!entry.line.contains(secret))
        #expect(!entry.line.contains("super-secret"))
    }

    // MARK: - Real file sink (append-only smoke test, isolated temp file)

    @Test func fileAuditLogAppendsOneLinePerEntryWithoutClobbering() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayback-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = FileAuditLog(fileURL: url)
        let first = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 1,
            event: .control("armed")
        )
        let second = AuditEntry(
            timestamp: Self.fixedTimestamp(),
            fromId: 2,
            event: .actionRan(command: "/uptime", exitCode: 0)
        )

        log.append(first)
        log.append(second)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines == [first.line, second.line])
    }
}
