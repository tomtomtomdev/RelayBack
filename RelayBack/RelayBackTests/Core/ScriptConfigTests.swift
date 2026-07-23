//
//  ScriptConfigTests.swift
//  RelayBackTests
//
//  S32 — `ScriptConfig` is one entry in the operator-picked local-script allowlist (§4d): a local
//  script file the Mac operator selects in Settings and triggers from Telegram via `/run`. These
//  tests pin two contracts:
//
//   1. Codable round-trip incl. a minimal/old blob (label + path only) decoding with the optional
//      fields defaulted — scripts persist as JSON in UserDefaults (S32), so a blob from a prior
//      version must not fail to decode and silently wipe the operator's script allowlist.
//   2. `toAction()` maps a valid entry to a fixed absolute executable + EMPTY argv (execve via the
//      script's shebang — never `/bin/sh -c`, I1), and **fails closed** (nil) on a non-absolute or
//      empty path so a bad entry is never runnable.
//

import Foundation
import Testing
@testable import RelayBack

struct ScriptConfigTests {

    // MARK: - Codable

    @Test func roundTripsThroughJSON() throws {
        let script = ScriptConfig(label: "Deploy Staging",
                                  path: "/Users/op/bin/deploy-staging.sh",
                                  workingDirectory: "/Users/op/dev/app",
                                  timeout: 120)
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(ScriptConfig.self, from: data)
        #expect(decoded == script)
    }

    // A minimal blob (label + path only) must still decode — workingDirectory nil, timeout the
    // default — so persisted JSON stays forward/backward-compatible (mirrors RepoConfig's tolerance).
    @Test func minimalBlobDecodesWithDefaults() throws {
        let json = #"{"label":"Backup","path":"/Users/op/bin/backup.sh"}"#
        let decoded = try JSONDecoder().decode(ScriptConfig.self, from: Data(json.utf8))
        #expect(decoded.label == "Backup")
        #expect(decoded.path == "/Users/op/bin/backup.sh")
        #expect(decoded.workingDirectory == nil)
        #expect(decoded.timeout == ScriptConfig.defaultTimeout)
    }

    // MARK: - toAction (I1: fixed absolute executable, empty argv, no shell)

    @Test func validScriptMapsToAbsoluteExecutableWithEmptyArgv() {
        let script = ScriptConfig(label: "Deploy Staging",
                                  path: "/Users/op/bin/deploy-staging.sh",
                                  workingDirectory: "/Users/op/dev/app",
                                  timeout: 120)
        let action = script.toAction()
        #expect(action?.executable == "/Users/op/bin/deploy-staging.sh")
        #expect(action?.arguments == [])                       // no argv from chat, no shell (I1)
        #expect(action?.workingDirectory == "/Users/op/dev/app")
        #expect(action?.timeout == 120)
        #expect(action?.command == "/deploy-staging")          // command token slugged from the label
        #expect(action?.description == "Deploy Staging")        // description is the label
    }

    @Test func toActionWithoutWorkingDirectoryInheritsCwd() {
        let action = ScriptConfig(label: "Backup", path: "/Users/op/bin/backup.sh").toAction()
        #expect(action?.workingDirectory == nil)
        #expect(action?.timeout == ScriptConfig.defaultTimeout)
    }

    // Fail-closed: a relative path is never runnable (the I1 check — a script path is only ever the
    // operator's absolute pick from the Settings file browser, never chat-supplied).
    @Test func relativePathFailsClosed() {
        #expect(ScriptConfig(label: "Bad", path: "bin/deploy.sh").toAction() == nil)
    }

    @Test func tildePathFailsClosed() {
        // `~/…` is not absolute (no leading slash) — refused; tilde expansion never happens.
        #expect(ScriptConfig(label: "Bad", path: "~/bin/deploy.sh").toAction() == nil)
    }

    @Test func emptyPathFailsClosed() {
        #expect(ScriptConfig(label: "Bad", path: "").toAction() == nil)
    }

    // A label that slugs to nothing (blank / punctuation-only) can't yield a usable command token —
    // fail closed rather than produce a degenerate "/" command.
    @Test func blankLabelFailsClosed() {
        #expect(ScriptConfig(label: "   ", path: "/Users/op/bin/x.sh").toAction() == nil)
        #expect(ScriptConfig(label: "!!!", path: "/Users/op/bin/x.sh").toAction() == nil)
    }
}
