//
//  SimulatorCommand.swift
//  RelayBack
//
//  S19 — the production `/sim` command (§4a dev-workflow epic), the first MULTI-STEP command. The
//  single-spawn git/build commands resolve to one `Action`; `/sim` resolves to an ordered SEQUENCE
//  of `Action`s (build → boot → reveal) that the coordinator runs in order, stopping on the first
//  non-zero exit. Every argv token comes only from the active repo's `RepoConfig` (scheme /
//  destination / simulatorDevice) — never operator text, never argv the operator can influence (I1).
//
//  Invariant I1 (no shell, ever): the three executables and the fixed argv words are in-code
//  constants; the only variable values (scheme, destination, device) are drawn from the configured
//  repo allowlist, not chat. A repo missing any required field makes the builder refuse rather than
//  spawning a partial sequence (§4a). I4: each step spawns an absolute-path tool as the normal user
//  under a restricted PATH. `/sim` takes NO operator arguments.
//

import Foundation

/// The `/sim` command's matching + advertising metadata, injected into `AuthGuard` (nil = not
/// enabled, the default). The step sequence itself is built by `SimulatorCommand.steps(for:)` from
/// the active repo's config, so this carries only the token + human description.
struct SimulatorCommandSpec: Equatable {
    let command: String
    let description: String
}

/// The outcome of building `/sim`'s step sequence: the ordered `Action`s to run, or a short,
/// secret-free reason the guard turns into a `⚠️` reply + audit line (nothing spawns).
enum SimulatorResolution: Equatable {
    case ok([Action])
    case invalid(reason: String)
}

enum SimulatorCommand {
    /// xcodebuild is slow (clean builds run minutes); give the build step a generous limit, and the
    /// quick simctl/open steps a short one. Matches the S18 `/build` timeout rationale.
    private static let buildTimeout: TimeInterval = 1800
    private static let simctlTimeout: TimeInterval = 120

    /// The canonical `/sim` spec — the single value production injects into the guard and advertises.
    static let spec = SimulatorCommandSpec(
        command: "/sim",
        description: "Build, boot & reveal the active repo's simulator")

    /// Builds the ordered `build → boot → reveal` step sequence for `/sim` from the active repo's
    /// config, or refuses if a required field is missing. Every token comes only from `repo` (I1);
    /// each step runs in the repo's root and is tagged with the `/sim` command token.
    static func steps(for repo: RepoConfig) -> SimulatorResolution {
        // §4a: refuse (nothing spawns) unless every value the sequence needs is configured. Missing
        // fields can only ever narrow what `/sim` reaches — never widen it — so this fails closed.
        guard let scheme = repo.scheme, !scheme.isEmpty else {
            return .invalid(reason: "no scheme configured for this repo")
        }
        guard let destination = repo.destination, !destination.isEmpty else {
            return .invalid(reason: "no destination configured for this repo")
        }
        guard let device = repo.simulatorDevice, !device.isEmpty else {
            return .invalid(reason: "no simulator device configured for this repo")
        }

        func step(_ description: String, _ executable: String, _ arguments: [String],
                  timeout: TimeInterval) -> Action {
            Action(command: spec.command, description: description, executable: executable,
                   arguments: arguments, timeout: timeout, workingDirectory: repo.root)
        }

        return .ok([
            // 1) Build the app for the configured simulator (fixed scheme/destination — S18 shape).
            step("Build for the simulator", "/usr/bin/xcodebuild",
                 ["-scheme", scheme, "-destination", destination, "build"], timeout: buildTimeout),
            // 2) Boot the configured device. `simctl boot` is idempotent-ish; a non-zero exit here
            //    (e.g. an unknown device) halts the sequence before the reveal step.
            step("Boot the simulator", "/usr/bin/xcrun",
                 ["simctl", "boot", device], timeout: simctlTimeout),
            // 3) Reveal the Simulator UI so the booted device is visible over screen-share. Fixed argv.
            step("Reveal the Simulator UI", "/usr/bin/open",
                 ["-a", "Simulator"], timeout: simctlTimeout),
        ])
    }
}
