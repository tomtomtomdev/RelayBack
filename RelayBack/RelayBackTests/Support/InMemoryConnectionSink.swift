//
//  InMemoryConnectionSink.swift
//  RelayBackTests
//
//  A `ConnectionSink` fake that keeps entries in memory so a test can assert exactly which
//  connection-lifecycle transitions the poll loop recorded (connected / disconnected) — and,
//  crucially, that a disconnect reason never carries a secret (invariant I3).
//

import Foundation
@testable import RelayBack

final class InMemoryConnectionSink: ConnectionSink {
    private(set) var entries: [ConnectionLogEntry] = []

    func append(_ entry: ConnectionLogEntry) { entries.append(entry) }
}
