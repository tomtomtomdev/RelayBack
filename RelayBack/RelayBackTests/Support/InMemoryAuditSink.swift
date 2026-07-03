//
//  InMemoryAuditSink.swift
//  RelayBackTests
//
//  An `AuditSink` fake that keeps entries in memory so a test can assert exactly what the
//  coordinator (S8) recorded — the decision reached and, for runs, the command + exit code —
//  and, crucially, that no entry ever carries command output or a secret (invariant I3).
//

import Foundation
@testable import RelayBack

final class InMemoryAuditSink: AuditSink {
    private(set) var entries: [AuditEntry] = []

    func append(_ entry: AuditEntry) { entries.append(entry) }
}
