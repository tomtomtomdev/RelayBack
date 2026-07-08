//
//  BuildCommandsTests.swift
//  RelayBackTests
//
//  S18 — the production `/build` command (§4a dev-workflow epic). Unlike the S17 git commands, the
//  argv is not fully fixed in code: the `-scheme` / `-destination` values are drawn from the active
//  repo's `RepoConfig` (never operator text, never argv the operator can influence). This slice pins
//  that: the resolver builds the exact `xcodebuild` argv from config, `/build` takes no operator
//  arguments, and a repo missing its scheme/destination config is refused (nothing spawns). No real
//  build runs in CI — argv + guard only (PLAN S18).
//

import Foundation
import Testing
@testable import RelayBack

struct BuildCommandsTests {

    private var buildSpec: ParameterizedCommand { BuildCommands.all.first { $0.command == "/build" }! }

    /// A fully-configured build repo, and one with no build config (a plain git repo).
    private var configured: RepoConfig {
        RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                   scheme: "RelayBack", destination: "platform=macOS")
    }
    private var noScheme: RepoConfig { RepoConfig(name: "notes", root: "/Users/op/dev/Notes") }
    private var noDestination: RepoConfig {
        RepoConfig(name: "half", root: "/Users/op/dev/Half", scheme: "Half")
    }

    private func resolve(argTokens: [String], activeRepo: RepoConfig?) -> ParameterResolution {
        ParameterizedActionResolver.resolve(buildSpec, argTokens: argTokens,
                                            repoTable: [:], activeRepo: activeRepo)
    }

    // MARK: - The spec is repo-scoped and spawns only /usr/bin/xcodebuild (I1 / §4a)

    @Test func buildIsRepoScopedXcodebuildOnly() {
        #expect(buildSpec.requiresActiveRepo)                  // §4a: runs in the active repo, /cd first
        #expect(buildSpec.executable == "/usr/bin/xcodebuild") // I1: fixed absolute executable
        #expect(buildSpec.parameters.isEmpty)                  // no operator-supplied parameter
        #expect(buildSpec.command == "/build")
    }

    // MARK: - argv is built from the active repo's config, never operator text

    @Test func buildBuildsArgvFromActiveRepoConfig() {
        guard case let .ok(action) = resolve(argTokens: [], activeRepo: configured) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(action.executable == "/usr/bin/xcodebuild")
        #expect(action.arguments == ["-scheme", "RelayBack", "-destination", "platform=macOS", "build"])
    }

    // MARK: - No operator argument is accepted

    @Test func buildAcceptsNoOperatorArguments() {
        // `/build clean` must not smuggle an extra xcodebuild action/flag through the operator text.
        #expect(resolve(argTokens: ["clean"], activeRepo: configured)
                == .invalid(reason: "unexpected extra input"))
    }

    // MARK: - A repo missing its build config is refused — nothing is built

    @Test func buildRejectsRepoWithNoScheme() {
        #expect(resolve(argTokens: [], activeRepo: noScheme)
                == .invalid(reason: "no scheme configured for this repo"))
    }

    @Test func buildRejectsRepoWithNoDestination() {
        #expect(resolve(argTokens: [], activeRepo: noDestination)
                == .invalid(reason: "no destination configured for this repo"))
    }
}
