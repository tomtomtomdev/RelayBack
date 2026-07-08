//
//  FileAuditReader.swift
//  RelayBack
//
//  S13f — the real `AuditReading`: reads the tail of the append-only audit file back into
//  `AuditEntry`s so the Settings Audit pane can show history. Thin by design — the line format
//  knowledge lives entirely in the pure, tested `AuditEntry.parse`; this impl only does the I/O
//  (read the file, split into lines, keep the last `limit`, parse each, drop anything unparseable).
//
//  Best-effort like the sink: a missing or unreadable file reads back as no entries rather than
//  throwing. Because a parsed entry can carry no output/secret (I3, S9), neither can this reader.
//

import Foundation

struct FileAuditReader: AuditReading {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func recentEntries(limit: Int) -> [AuditEntry] {
        guard limit > 0, let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return []
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).compactMap { AuditEntry.parse(line: String($0)) }
    }
}
