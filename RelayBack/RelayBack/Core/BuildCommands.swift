//
//  BuildCommands.swift
//  RelayBack
//
//  S18 — the production `/build` command (§4a dev-workflow epic). Like the S17 git commands it is a
//  fixed `/usr/bin/xcodebuild` invocation running in the session's active repo, but its `-scheme` /
//  `-destination` values are drawn from that repo's `RepoConfig` (S16) — NOT from operator text and
//  NOT from an argv slot the operator can influence. `/build` takes no operator arguments at all.
//
//  Invariant I1 (no shell, ever): the executable, the fixed `build` action, and the two config flags
//  are in-code constants; the only variable values (scheme/destination) come from the configured repo
//  allowlist, not chat. A repo with no scheme/destination configured makes the resolver refuse (§4a).
//  I4: the runner spawns `/usr/bin/xcodebuild` as the normal user under a restricted PATH.
//

import Foundation

enum BuildCommands {
    /// xcodebuild is slow (clean builds can run many minutes); give it a generous wall-clock limit.
    private static let buildTimeout: TimeInterval = 1800

    /// The single `/build` spec: `xcodebuild -scheme <cfg.scheme> -destination <cfg.destination> build`,
    /// repo-scoped so it runs in the active repo's root (`/cd <repo>` first). No operator parameters.
    static let all: [ParameterizedCommand] = [
        ParameterizedCommand(
            command: "/build", description: "Build the active repo's scheme",
            executable: "/usr/bin/xcodebuild",
            fixedArgs: ["build"],
            configArgs: [.scheme, .destination],
            parameters: [], timeout: buildTimeout, requiresActiveRepo: true),
    ]
}
