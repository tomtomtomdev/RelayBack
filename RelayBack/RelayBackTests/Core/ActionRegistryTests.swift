//
//  ActionRegistryTests.swift
//  RelayBackTests
//
//  S2 — Action allowlist & registry. The registry is the single source of what may run
//  (invariant I1): only its fixed command → absolute-path + arg-array entries are matchable.
//  Operator text is used ONLY to look up an entry; it never becomes an executable or argument.
//

import Foundation
import Testing
@testable import RelayBack

struct ActionRegistryTests {

    // MARK: - Exact leading-token match

    @Test func matchesKnownCommandExactly() throws {
        let action = try #require(ActionRegistry.seed.match("/uptime"))
        #expect(action.command == "/uptime")
        // The spawned executable is a fixed absolute path, never derived from operator text.
        #expect(action.executable.hasPrefix("/"))
    }

    @Test func matchesAllSeededCommands() {
        for command in ["/uptime", "/disk", "/whoami", "/ip",
                        "/mem", "/top", "/ps", "/netstat", "/battery", "/date"] {
            #expect(ActionRegistry.seed.match(command)?.command == command)
        }
    }

    @Test func ipRunsFixedAbsolutePathWithNoOperatorArgs() throws {
        // /ip is a read-only network-interface dump: fixed absolute executable, fixed args,
        // nothing derived from operator text (invariant I1).
        let action = try #require(ActionRegistry.seed.match("/ip"))
        #expect(action.executable == "/sbin/ifconfig")
        #expect(action.executable.hasPrefix("/"))
    }

    // Each read-only diagnostic names a fixed absolute executable and a fixed argument array;
    // operator text only selects the entry — it never becomes the executable or an argument (I1).
    @Test func readOnlyDiagnosticsHaveFixedAbsoluteExecutableAndArgs() throws {
        let expected: [String: (executable: String, arguments: [String])] = [
            "/mem":     ("/usr/bin/vm_stat", []),
            "/top":     ("/usr/bin/top", ["-l", "1", "-n", "15", "-o", "cpu"]),
            "/ps":      ("/bin/ps", ["aux"]),
            "/netstat": ("/usr/sbin/netstat", ["-rn"]),
            "/battery": ("/usr/bin/pmset", ["-g", "batt"]),
            "/date":    ("/bin/date", []),
        ]
        for (command, spec) in expected {
            let action = try #require(ActionRegistry.seed.match(command), "\(command) missing")
            #expect(action.executable == spec.executable)
            #expect(action.executable.hasPrefix("/"))
            #expect(action.arguments == spec.arguments)
        }
    }

    @Test func unknownCommandReturnsNil() {
        #expect(ActionRegistry.seed.match("/reboot") == nil)
        #expect(ActionRegistry.seed.match("/rm") == nil)
    }

    // MARK: - Leading-token semantics

    @Test func matchesOnLeadingTokenIgnoringTrailingText() throws {
        // Only the leading token selects the action; trailing text is discarded (never
        // used as an argument — invariant I1). The action still runs its fixed args.
        let action = try #require(ActionRegistry.seed.match("/uptime and then rm -rf /"))
        #expect(action.command == "/uptime")
    }

    @Test func partialTokenDoesNotMatch() {
        // A token that merely starts with a command name is not an exact match.
        #expect(ActionRegistry.seed.match("/uptimes") == nil)
        #expect(ActionRegistry.seed.match("/disking") == nil)
    }

    // MARK: - Leading-slash rule

    @Test func requiresLeadingSlash() {
        #expect(ActionRegistry.seed.match("uptime") == nil)
        #expect(ActionRegistry.seed.match("whoami") == nil)
    }

    // MARK: - Casing

    @Test func matchIsCaseInsensitive() {
        #expect(ActionRegistry.seed.match("/UPTIME")?.command == "/uptime")
        #expect(ActionRegistry.seed.match("/Uptime")?.command == "/uptime")
        #expect(ActionRegistry.seed.match("/WhoAmI")?.command == "/whoami")
    }

    // MARK: - Empty / whitespace input

    @Test func emptyOrWhitespaceReturnsNil() {
        #expect(ActionRegistry.seed.match("") == nil)
        #expect(ActionRegistry.seed.match("   ") == nil)
        #expect(ActionRegistry.seed.match("\n") == nil)
    }

    // MARK: - Control commands are NOT actions (handled by AuthGuard, S3)

    @Test func controlCommandsAreNotActions() {
        for control in ["/arm", "/arm 123456", "/disarm", "/status"] {
            #expect(ActionRegistry.seed.match(control) == nil)
        }
    }
}
