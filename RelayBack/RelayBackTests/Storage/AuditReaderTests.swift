//
//  AuditReaderTests.swift
//  RelayBackTests
//
//  S13f — the READ side of the audit log (the S9 `AuditSink` is write-only). Two surfaces:
//
//  1. `AuditEntry.parse(line:)` — the pure inverse of `AuditEntry.line`. It reconstructs the
//     narrow `AuditEvent` (actionRan / control / rejected) from a stored line so the Audit pane
//     can render past history. It round-trips every event kind; a malformed line returns nil
//     rather than trapping. Because the line format has no output/secret field (I3, S9), a parsed
//     entry structurally cannot carry one either.
//  2. `FileAuditReader` — the real bounded-tail reader, verified by an isolated temp-file smoke
//     test: lines written by `FileAuditLog` read back (in file order) through the pure parser.
//

import Foundation
import Testing
@testable import RelayBack

struct AuditReaderTests {

    private func fixedTimestamp() -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 3; c.hour = 15; c.minute = 4; c.second = 5
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: c)!
    }

    // MARK: - Pure parse (round-trips AuditEntry.line)

    @Test func parseRoundTripsAnActionRan() {
        let entry = AuditEntry(timestamp: fixedTimestamp(), fromId: 481920774,
                               event: .actionRan(command: "/uptime", exitCode: 0))
        #expect(AuditEntry.parse(line: entry.line) == entry)
    }

    @Test func parseRoundTripsANonZeroExit() {
        let entry = AuditEntry(timestamp: fixedTimestamp(), fromId: 42,
                               event: .actionRan(command: "/disk", exitCode: 1))
        #expect(AuditEntry.parse(line: entry.line) == entry)
    }

    @Test func parseRoundTripsAControlEvent() {
        let entry = AuditEntry(timestamp: fixedTimestamp(), fromId: 7,
                               event: .control("status armed=true"))
        #expect(AuditEntry.parse(line: entry.line) == entry)
    }

    @Test func parseRoundTripsARejection() {
        let entry = AuditEntry(timestamp: fixedTimestamp(), fromId: 999,
                               event: .rejected(reason: "unknown user"))
        #expect(AuditEntry.parse(line: entry.line) == entry)
    }

    @Test func parseReturnsNilForAMalformedLine() {
        #expect(AuditEntry.parse(line: "not an audit line") == nil)
        #expect(AuditEntry.parse(line: "") == nil)
    }

    // MARK: - Fake-backed read side

    @Test func inMemoryReaderReturnsCappedEntries() {
        let entries = (0..<10).map {
            AuditEntry(timestamp: Date(timeIntervalSince1970: TimeInterval($0)), fromId: 1,
                       event: .control("armed"))
        }
        let reader = InMemoryAuditReader(entries: entries)
        #expect(reader.recentEntries(limit: 3).count == 3)
    }

    // MARK: - Real file reader (append-only smoke test, isolated temp file)

    @Test func fileReaderReadsBackWhatTheSinkWrote() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayback-audit-read-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = FileAuditLog(fileURL: url)
        let a = AuditEntry(timestamp: fixedTimestamp(), fromId: 1, event: .control("armed"))
        let b = AuditEntry(timestamp: fixedTimestamp(), fromId: 2,
                           event: .actionRan(command: "/uptime", exitCode: 0))
        log.append(a)
        log.append(b)

        let reader = FileAuditReader(fileURL: url)
        #expect(reader.recentEntries(limit: 100) == [a, b])   // file order (oldest → newest)
    }

    @Test func fileReaderIsEmptyWhenNoFileExists() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayback-audit-missing-\(UUID().uuidString).log")
        let reader = FileAuditReader(fileURL: url)
        #expect(reader.recentEntries(limit: 10).isEmpty)
    }
}
