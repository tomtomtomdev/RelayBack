//
//  FileConnectionLog.swift
//  RelayBack
//
//  The real `ConnectionSink`: an append-only local text file, one line per connection transition.
//  Thin by design — the line content comes from the pure, tested `ConnectionLogEntry.line`, and the
//  best-effort append is delegated to the shared `AppendOnlyFile`. Write failures are swallowed so a
//  full/locked disk degrades logging rather than breaking the poll loop.
//

import Foundation

struct FileConnectionLog: ConnectionSink {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ entry: ConnectionLogEntry) {
        AppendOnlyFile.append(entry.line, to: fileURL)
    }
}
