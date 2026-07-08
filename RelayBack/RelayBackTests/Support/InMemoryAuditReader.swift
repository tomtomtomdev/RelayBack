//
//  InMemoryAuditReader.swift
//  RelayBackTests
//
//  A `AuditReading` fake that returns canned entries, so `AuditRowPresentation` and the Settings
//  Audit pane can be tested without touching the real log file (S13f). Mirrors `InMemoryAuditSink`.
//

import Foundation
@testable import RelayBack

final class InMemoryAuditReader: AuditReading {
    var entries: [AuditEntry]
    init(entries: [AuditEntry] = []) { self.entries = entries }

    func recentEntries(limit: Int) -> [AuditEntry] {
        Array(entries.suffix(limit))
    }
}
