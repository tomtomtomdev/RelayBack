//
//  TempFileCurlConfigWriter.swift
//  RelayBack
//
//  S29 — the real `CurlConfigWriting`. Writes the `curl --config` body to a uniquely-named file in the
//  system temp directory with 0600 permissions, so the PGYER API key it carries is readable only by
//  this user and never reaches argv (§4c / I3). Thin real I/O: per CLAUDE it is verified by a focused
//  smoke test (`CurlConfigWriterTests`), not by faking its logic.
//

import Foundation

struct TempFileCurlConfigWriter: CurlConfigWriting {
    func writeConfig(_ body: String) throws -> String {
        // Unique name so concurrent uploads never share a file; `.conf` is cosmetic.
        let name = "relayback-upload-\(UUID().uuidString).conf"
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        // Create owner-only (0600) BEFORE writing, so the key bytes are never briefly world-readable.
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        guard FileManager.default.createFile(atPath: url.path,
                                             contents: Data(body.utf8),
                                             attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return url.path
    }

    func removeConfig(at path: String) {
        try? FileManager.default.removeItem(atPath: path)   // best-effort; see protocol doc.
    }
}
