//
//  CurlConfigWriterTests.swift
//  RelayBackTests
//
//  S29 — a focused smoke test for the thin real `CurlConfigWriting` impl (§4c). Per CLAUDE, thin I/O
//  types get one focused smoke test rather than a fake: here we prove the config file is created with
//  the exact body, is 0600 (owner-only — so the PGYER key it carries is never world-readable, I3), and
//  is deleted by `removeConfig`. Real filesystem, but only in the temp dir — allowed (not Keychain,
//  not network, not a long-running process).
//

import Foundation
import Testing
@testable import RelayBack

struct CurlConfigWriterTests {

    @Test func writesTheExactBodyAsAnOwnerOnlyFileThenDeletesIt() throws {
        let writer = TempFileCurlConfigWriter()
        let body = "form = \"_api_key=SECRET\"\nform = \"file=@/tmp/App.ipa\"\n"

        let path = try writer.writeConfig(body)

        // The file exists and holds exactly what we wrote.
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == body)

        // 0600: readable/writable by the owner only — the key is never exposed to other users (I3).
        let perms = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        #expect(perms?.int16Value == 0o600)

        // removeConfig deletes it — the key file must not outlive the spawn.
        writer.removeConfig(at: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func eachWriteUsesAFreshPath() throws {
        // Concurrent uploads must never share a config file (one deleting the other's key file).
        let writer = TempFileCurlConfigWriter()
        let a = try writer.writeConfig("a")
        let b = try writer.writeConfig("b")
        #expect(a != b)
        writer.removeConfig(at: a)
        writer.removeConfig(at: b)
    }
}
