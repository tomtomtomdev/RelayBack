//
//  RepoConfig.swift
//  RelayBack
//
//  S16 — one entry in the configured **repo allowlist** (§4a): a named working directory the
//  dev-workflow actions operate in. Pure value type, persisted (non-secret) via `ConfigStore`.
//
//  The `name` is the only thing the operator ever types (`/cd <name>`); it is matched exactly
//  against this list, so no path ever comes from chat and directory traversal is impossible.
//  `root` is the absolute directory the guard hands to `Process.currentDirectoryURL` for that
//  repo's commands. `scheme` / `destination` / `simulatorDevice` are fixed per-repo build config
//  consumed by the later `/build` (S18) and `/sim` (S19) commands — never derived from operator
//  text — and are optional because a plain git repo needs none of them.
//

import Foundation

struct RepoConfig: Equatable, Codable, Identifiable {
    /// Operator-facing name selected with `/cd <name>`; matched exactly against the allowlist.
    let name: String
    /// Absolute path to the repo's working directory (the only path — never from chat).
    let root: String
    /// Fixed `xcodebuild -scheme` value for `/build` (S18); nil for a repo with no build config.
    let scheme: String?
    /// Fixed `xcodebuild -destination` value for `/build` (S18); nil when unconfigured.
    let destination: String?
    /// Fixed simulator device for `/sim` (S19); nil when unconfigured.
    let simulatorDevice: String?

    /// Stable identity for SwiftUI lists — the name is unique within the allowlist.
    var id: String { name }

    init(name: String,
         root: String,
         scheme: String? = nil,
         destination: String? = nil,
         simulatorDevice: String? = nil) {
        self.name = name
        self.root = root
        self.scheme = scheme
        self.destination = destination
        self.simulatorDevice = simulatorDevice
    }
}
