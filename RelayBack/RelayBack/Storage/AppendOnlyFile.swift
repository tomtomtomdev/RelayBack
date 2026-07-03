//
//  AppendOnlyFile.swift
//  RelayBack
//
//  The shared, best-effort append-only file write behind both local logs (audit + connection).
//  Appends one line + newline to the end of a file, creating the file (and its parent directory)
//  on first write and never truncating earlier lines. All I/O errors are swallowed: logging is
//  background bookkeeping and must never interrupt command handling or the poll loop.
//

import Foundation

enum AppendOnlyFile {
    static func append(_ line: String, to fileURL: URL) {
        guard let data = (line + "\n").data(using: .utf8) else { return }

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
