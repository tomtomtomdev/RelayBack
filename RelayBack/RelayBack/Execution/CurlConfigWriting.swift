//
//  CurlConfigWriting.swift
//  RelayBack
//
//  S29 — the seam for the 0600 `curl --config` file that carries the PGYER upload's multipart form
//  fields (§4c). It exists so the API key NEVER reaches argv: instead of `curl -F _api_key=<key>`
//  (which would show the key in `ps`), the coordinator spawns `curl --config <file> <url>` where the
//  key lives only inside a short-lived, owner-only-readable temp file.
//
//  Invariant I3 (secrets only in Keychain, and out of argv): the key is read from the Keychain only at
//  upload time, folded into the config body by `PgyerUpload.configFileBody(apiKey:)`, written here to a
//  0600 file, and deleted immediately after the spawn. It never enters the process argv (`ps`), the
//  audit log, or a Telegram reply. `AppCoordinator` (S29) depends on this protocol and is tested
//  against a fake; the real implementation is `TempFileCurlConfigWriter`.
//

import Foundation

protocol CurlConfigWriting {
    /// Write `body` to a fresh temp file with 0600 permissions (owner read/write only) and return its
    /// absolute path. Throws if the file cannot be created — the caller then fails the upload closed.
    func writeConfig(_ body: String) throws -> String

    /// Delete the config file at `path`. Best-effort: called right after the spawn so the key file
    /// does not outlive the upload. A failure here is non-fatal (the file is already 0600 and in a
    /// temp dir), so this does not throw.
    func removeConfig(at path: String)
}
