//
//  FileAuditLog.swift
//  RelayBack
//
//  S9 — the real `AuditSink`: an append-only local text file, one line per received command
//  (FR-8). Each `append` writes `entry.line` + newline to the end of the file, creating the
//  file (and its parent directory) on first write and never truncating earlier lines.
//
//  Best-effort by design: auditing must never interrupt command handling, so write failures
//  are swallowed here rather than propagated (the protocol is non-throwing). The line content
//  comes from the pure, tested `AuditEntry.line`, which guarantees no secret and no embedded
//  newline can reach the file — so this impl stays thin and holds no formatting logic itself.
//

import Foundation

struct FileAuditLog: AuditSink {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func append(_ entry: AuditEntry) {
        guard let data = (entry.line + "\n").data(using: .utf8) else { return }

        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            try? manager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: fileURL, options: .atomic)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
