//
//  SimulatorCommandTests.swift
//  RelayBackTests
//
//  S19 — the production `/sim` command (§4a dev-workflow epic), the first MULTI-STEP command. Unlike
//  the single-spawn git/build commands, `/sim` resolves to an ordered SEQUENCE of `Action`s built
//  entirely from the active repo's `RepoConfig` (scheme/destination/simulatorDevice) — never operator
//  text, never argv the operator can influence. This slice pins that: the builder emits the exact
//  build → boot → reveal argv sequence from config, and a repo missing any required field is refused
//  (nothing is built). No real simulator runs in CI — argv sequence + guard only (PLAN S19); the
//  end-to-end run is macOS-manual (steps recorded in PROGRESS.md).
//

import Foundation
import Testing
@testable import RelayBack

struct SimulatorCommandTests {

    /// A fully-configured simulator repo, and repos missing one required field each.
    private var configured: RepoConfig {
        RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                   scheme: "RelayBack", destination: "platform=iOS Simulator,name=iPhone 15",
                   simulatorDevice: "iPhone 15")
    }
    private var noScheme: RepoConfig { RepoConfig(name: "notes", root: "/Users/op/dev/Notes") }
    private var noDestination: RepoConfig {
        RepoConfig(name: "half", root: "/Users/op/dev/Half", scheme: "Half")
    }
    private var noDevice: RepoConfig {
        RepoConfig(name: "nodev", root: "/Users/op/dev/NoDev",
                   scheme: "NoDev", destination: "platform=iOS Simulator,name=iPhone 15")
    }

    // MARK: - The spec is the single `/sim` command token (for matching / advertising)

    @Test func specIsTheSimCommandToken() {
        #expect(SimulatorCommand.spec.command == "/sim")
        #expect(!SimulatorCommand.spec.description.isEmpty)
    }

    // MARK: - argv SEQUENCE is built from the active repo's config, never operator text (I1)

    @Test func buildsBuildBootRevealSequenceFromConfig() {
        guard case let .ok(steps) = SimulatorCommand.steps(for: configured) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(steps.count == 3)

        // Step 1 — build for the simulator with the repo's fixed scheme/destination.
        #expect(steps[0].executable == "/usr/bin/xcodebuild")
        #expect(steps[0].arguments ==
                ["-scheme", "RelayBack",
                 "-destination", "platform=iOS Simulator,name=iPhone 15", "build"])

        // Step 2 — boot the configured device via xcrun simctl.
        #expect(steps[1].executable == "/usr/bin/xcrun")
        #expect(steps[1].arguments == ["simctl", "boot", "iPhone 15"])

        // Step 3 — reveal the Simulator UI (no config; fixed argv).
        #expect(steps[2].executable == "/usr/bin/open")
        #expect(steps[2].arguments == ["-a", "Simulator"])
    }

    // MARK: - Every step runs in the active repo root, tagged with the /sim token (I1/I4)

    @Test func everyStepRunsInTheRepoRootAsSim() {
        guard case let .ok(steps) = SimulatorCommand.steps(for: configured) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(steps.allSatisfy { $0.workingDirectory == "/Users/op/dev/RelayBack" })
        #expect(steps.allSatisfy { $0.command == "/sim" })
        // I1/I4: only fixed absolute executables are ever spawned — no operator text reaches the slot.
        #expect(steps.allSatisfy { $0.executable.hasPrefix("/usr/bin/") })
    }

    // MARK: - A repo missing any required build/sim config is refused — nothing is built

    @Test func rejectsRepoWithNoScheme() {
        #expect(SimulatorCommand.steps(for: noScheme)
                == .invalid(reason: "no scheme configured for this repo"))
    }

    @Test func rejectsRepoWithNoDestination() {
        #expect(SimulatorCommand.steps(for: noDestination)
                == .invalid(reason: "no destination configured for this repo"))
    }

    @Test func rejectsRepoWithNoSimulatorDevice() {
        #expect(SimulatorCommand.steps(for: noDevice)
                == .invalid(reason: "no simulator device configured for this repo"))
    }
}
