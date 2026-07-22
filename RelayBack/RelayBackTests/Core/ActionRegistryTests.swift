//
//  ActionRegistryTests.swift
//  RelayBackTests
//
//  S2 — Action allowlist & registry. The registry is the single source of what may run
//  (invariant I1): only its fixed command → absolute-path + arg-array entries are matchable.
//  Operator text is used ONLY to look up an entry; it never becomes an executable or argument.
//
//  The `seed` allowlist is now empty (the legacy read-only diagnostics were removed; the app's
//  runnable surface is the repo-scoped git/build/sim commands, S16–S19). Match() semantics are
//  therefore exercised against a small local `fixture` registry, independent of the seed.
//

import Foundation
import Testing
@testable import RelayBack

struct ActionRegistryTests {

    /// A small registry for exercising `match()` semantics independently of the (empty) seed.
    private let fixture = ActionRegistry(actions: [
        Action(command: "/disk",
               description: "Disk usage, human-readable",
               executable: "/bin/df",
               arguments: ["-h"],
               timeout: 10),
    ])

    // MARK: - Seed allowlist is empty

    @Test func seedAllowlistIsEmpty() {
        #expect(ActionRegistry.seed.actions.isEmpty)
    }

    // The legacy diagnostics were removed from the seed and must no longer be matchable there.
    @Test func removedDiagnosticsAreNotAllowlisted() {
        for command in ["/uptime", "/disk", "/whoami", "/ip", "/mem",
                        "/top", "/ps", "/netstat", "/battery", "/date"] {
            #expect(ActionRegistry.seed.match(command) == nil, "\(command) should not be allowlisted")
            #expect(ActionRegistry.seed.match(command.uppercased()) == nil, "\(command) casing")
        }
    }

    // MARK: - Exact leading-token match

    @Test func matchesKnownCommandExactly() throws {
        let action = try #require(fixture.match("/disk"))
        #expect(action.command == "/disk")
        // The spawned executable is a fixed absolute path, never derived from operator text.
        #expect(action.executable.hasPrefix("/"))
    }

    @Test func unknownCommandReturnsNil() {
        #expect(fixture.match("/reboot") == nil)
        #expect(fixture.match("/rm") == nil)
    }

    // MARK: - Leading-token semantics

    @Test func matchesOnLeadingTokenIgnoringTrailingText() throws {
        // Only the leading token selects the action; trailing text is discarded (never
        // used as an argument — invariant I1). The action still runs its fixed args.
        let action = try #require(fixture.match("/disk and then rm -rf /"))
        #expect(action.command == "/disk")
    }

    @Test func partialTokenDoesNotMatch() {
        // A token that merely starts with a command name is not an exact match.
        #expect(fixture.match("/disks") == nil)
        #expect(fixture.match("/disking") == nil)
    }

    // MARK: - Leading-slash rule

    @Test func requiresLeadingSlash() {
        #expect(fixture.match("disk") == nil)
        #expect(fixture.match("whoami") == nil)
    }

    // MARK: - Casing

    @Test func matchIsCaseInsensitive() {
        #expect(fixture.match("/DISK")?.command == "/disk")
        #expect(fixture.match("/Disk")?.command == "/disk")
    }

    // MARK: - Empty / whitespace input

    @Test func emptyOrWhitespaceReturnsNil() {
        #expect(fixture.match("") == nil)
        #expect(fixture.match("   ") == nil)
        #expect(fixture.match("\n") == nil)
    }

    // MARK: - Control commands are NOT actions (handled by AuthGuard, S3)

    @Test func controlCommandsAreNotActions() {
        for control in ["/arm", "/arm 123456", "/disarm", "/status"] {
            #expect(fixture.match(control) == nil)
        }
    }
}
