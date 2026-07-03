//
//  ConnectionLogTests.swift
//  RelayBackTests
//
//  The connection-lifecycle log contract (persistent, append-only, invariant I3). Three surfaces:
//
//  1. `ConnectionLogEntry.line` — the PURE, one-line rendering of a connect/disconnect transition.
//     Must carry timestamp + the event and NOTHING that could leak a secret; free text in a
//     disconnect reason is neutralized so one transition can only ever produce one log line.
//  2. `ConnectionReason.from(_:)` — maps a transport error to a SHORT, secret-free reason. It must
//     never embed the failing URL (which carries the bot token in its path) — invariant I3.
//  3. `FileConnectionLog` — the real append-only file sink, verified by an isolated temp-file smoke
//     test (safe I/O, no network): appends round-trip through the pure formatter and never clobber.
//

import Foundation
import Testing
@testable import RelayBack

struct ConnectionLogTests {

    /// A fixed, deterministic instant: 2026-07-03T15:04:05Z (built without the formatter under test).
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

    @Test func connectedLineHasTimestampAndEvent() {
        let entry = ConnectionLogEntry(timestamp: Self.fixedTimestamp(), event: .connected)
        #expect(entry.line == "2026-07-03T15:04:05Z connection=connected")
    }

    @Test func disconnectedLineShowsReason() {
        let entry = ConnectionLogEntry(
            timestamp: Self.fixedTimestamp(),
            event: .disconnected(reason: "network error -1009")
        )
        #expect(entry.line == #"2026-07-03T15:04:05Z connection=disconnected reason="network error -1009""#)
    }

    @Test func disconnectReasonNewlinesAreNeutralizedToKeepOneLinePerEntry() {
        let entry = ConnectionLogEntry(
            timestamp: Self.fixedTimestamp(),
            event: .disconnected(reason: "boom\n2026-01-01T00:00:00Z connection=connected")
        )
        #expect(!entry.line.contains("\n"))
        #expect(!entry.line.contains("\r"))
    }

    // MARK: - Invariant I3 — a disconnect reason never leaks the token-bearing URL

    @Test func disconnectReasonNeverLeaksTheFailingURLOrToken() {
        // The Telegram base URL embeds the bot token in its path; a URLError can carry that URL in
        // its userInfo. The classifier must reduce to a code-only reason, never the URL/token.
        let tokenURL = "https://api.telegram.org/bot987654:SUPER-SECRET-TOKEN/getUpdates"
        let error = URLError(.notConnectedToInternet,
                             userInfo: [NSURLErrorFailingURLStringErrorKey: tokenURL])

        let reason = ConnectionReason.from(error)

        #expect(!reason.contains("SUPER-SECRET-TOKEN"))
        #expect(!reason.contains("987654"))
        #expect(!reason.contains("api.telegram.org"))
    }

    @Test func nonURLErrorMapsToAGenericTransportReason() {
        enum SomeTransportError: Error { case down }
        #expect(ConnectionReason.from(SomeTransportError.down) == "transport error")
    }

    // MARK: - Real file sink (append-only smoke test, isolated temp file)

    @Test func fileConnectionLogAppendsOneLinePerEntryWithoutClobbering() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayback-connection-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }

        let log = FileConnectionLog(fileURL: url)
        let first = ConnectionLogEntry(timestamp: Self.fixedTimestamp(), event: .connected)
        let second = ConnectionLogEntry(
            timestamp: Self.fixedTimestamp(),
            event: .disconnected(reason: "transport error")
        )

        log.append(first)
        log.append(second)

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(lines == [first.line, second.line])
    }
}
