//
//  ParameterizedActionResolverTests.swift
//  RelayBackTests
//
//  S15 — the resolver is the single place a parameterized command + operator tokens becomes a
//  runnable `Action`. It is the executable statement of §4a: the executable and the leading argv
//  come only from the (fixed) spec; each operator token is validated and lands at a fixed argv
//  index (a value-bearing arg sits behind a `--` guard so it can never be read as a flag); a repo
//  name resolves to an absolute root drawn only from the configured allowlist (never chat), which
//  becomes the working directory. Invalid input yields `.invalid(reason)` and builds nothing.
//

import Foundation
import Testing
@testable import RelayBack

struct ParameterizedActionResolverTests {

    private let repos: [String: String] = ["relayback": "/Users/op/dev/RelayBack"]

    // Representative specs — S15 wires none of these into production (nothing is matchable yet);
    // they exist to exercise the mechanism, standing in for the S17+ git/build commands.
    private let checkout = ParameterizedCommand(
        command: "/checkout", description: "Switch branch",
        executable: "/usr/bin/git", fixedArgs: ["checkout", "--"],
        parameters: [.branch], timeout: 20)

    private let commit = ParameterizedCommand(
        command: "/commit", description: "Commit tracked changes",
        executable: "/usr/bin/git", fixedArgs: ["commit", "-a", "-m"],
        parameters: [.commitMessage], timeout: 20)

    private let cd = ParameterizedCommand(
        command: "/cd", description: "Select active repo",
        executable: "/usr/bin/true", fixedArgs: [],
        parameters: [.repoName], timeout: 5)

    private let gitStatus = ParameterizedCommand(
        command: "/gitstatus", description: "Working tree status",
        executable: "/usr/bin/git", fixedArgs: ["status"],
        parameters: [], timeout: 20)

    // MARK: - Builds the exact fixed argv from validated tokens only

    @Test func buildsBranchArgvBehindTheDashDashGuard() {
        let result = ParameterizedActionResolver.resolve(checkout, argTokens: ["main"], repoTable: repos)
        guard case let .ok(action) = result else { return #expect(Bool(false), "expected .ok") }
        // Executable + leading argv are fixed; the validated branch sits after the `--` guard.
        #expect(action.executable == "/usr/bin/git")
        #expect(action.arguments == ["checkout", "--", "main"])
        #expect(action.command == "/checkout")
        #expect(action.workingDirectory == nil)   // no repo param on this spec
    }

    @Test func buildsCommitArgvWithTheMessageAsASingleToken() {
        let result = ParameterizedActionResolver.resolve(
            commit, argTokens: ["fix the login crash"], repoTable: repos)
        guard case let .ok(action) = result else { return #expect(Bool(false), "expected .ok") }
        #expect(action.arguments == ["commit", "-a", "-m", "fix the login crash"])
    }

    @Test func repoNameParamSetsWorkingDirectoryAndAddsNoArgv() {
        let result = ParameterizedActionResolver.resolve(cd, argTokens: ["relayback"], repoTable: repos)
        guard case let .ok(action) = result else { return #expect(Bool(false), "expected .ok") }
        #expect(action.workingDirectory == "/Users/op/dev/RelayBack")
        #expect(action.arguments == [])            // a repo name selects a directory, not an arg
    }

    @Test func zeroParameterCommandBuildsItsFixedArgv() {
        let result = ParameterizedActionResolver.resolve(gitStatus, argTokens: [], repoTable: repos)
        guard case let .ok(action) = result else { return #expect(Bool(false), "expected .ok") }
        #expect(action.arguments == ["status"])
    }

    // MARK: - Refuses bad input — nothing is built

    @Test func rejectsBranchWithMetacharactersOrLeadingDash() {
        #expect(ParameterizedActionResolver.resolve(checkout, argTokens: ["-x"], repoTable: repos)
                == .invalid(reason: "invalid branch name"))
        #expect(ParameterizedActionResolver.resolve(checkout, argTokens: ["a; rm -rf /"], repoTable: repos)
                == .invalid(reason: "invalid branch name"))
    }

    @Test func rejectsCommitMessageWithLeadingDash() {
        #expect(ParameterizedActionResolver.resolve(commit, argTokens: ["-m evil"], repoTable: repos)
                == .invalid(reason: "invalid commit message"))
    }

    @Test func rejectsUnknownRepo() {
        #expect(ParameterizedActionResolver.resolve(cd, argTokens: ["nope"], repoTable: repos)
                == .invalid(reason: "unknown repo"))
    }

    @Test func rejectsWrongArgumentCount() {
        // Missing the required branch.
        #expect(ParameterizedActionResolver.resolve(checkout, argTokens: [], repoTable: repos)
                == .invalid(reason: "missing parameter"))
        // A zero-parameter command must accept no operator input (guards /push, /pull in S17).
        #expect(ParameterizedActionResolver.resolve(gitStatus, argTokens: ["extra"], repoTable: repos)
                == .invalid(reason: "unexpected extra input"))
    }
}
