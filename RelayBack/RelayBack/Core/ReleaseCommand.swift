//
//  ReleaseCommand.swift
//  RelayBack
//
//  S28 — the pure `/release` + `/pgyer` builder (§4c release-&-distribution epic). `/release` builds
//  an iOS archive, exports an `.ipa`, and uploads it to PGYER; `/pgyer` runs the upload step alone on
//  a pre-built artifact. Like `/sim` (§4a), `/release` resolves to an ordered SEQUENCE of `Action`s
//  (archive → export) that the S29 coordinator runs in order, stopping on the first non-zero exit,
//  then performs the upload. Every argv token comes only from the active repo's `RepoConfig` + the
//  configured endpoint URL — never operator text, never argv the operator can influence (I1).
//
//  Invariant I1 (no shell, ever): the executables and fixed argv words (`archive`, `-exportArchive`,
//  `-sdk iphoneos`, `-configuration Release`) are in-code constants; the only variable values
//  (workspace, scheme, plist, artifact, url, note) are drawn from config, not chat. A repo missing
//  any required field makes the builder refuse rather than spawning a partial pipeline (§4c, fails
//  closed). I4: each step spawns an absolute-path tool as the normal user under a restricted PATH.
//
//  Invariant I3 (secrets only in Keychain): the PGYER API key is NEVER part of the returned plan.
//  This builder takes no key at all — the key is read from the Keychain only at spawn time and folded
//  into `PgyerUpload.configFileBody(apiKey:)`, which the coordinator writes to a 0600 `curl --config`
//  file so the key never reaches argv (`ps`), the audit log, or a reply. `/release`/`/pgyer` take NO
//  operator arguments.
//

import Foundation

/// A `/release`/`/pgyer` command's matching + advertising metadata, injected into `AuthGuard` (nil =
/// not enabled). The step sequence + upload metadata are built by the pure builders below from the
/// active repo's config, so this carries only the token + human description (mirrors `SimulatorCommandSpec`).
struct ReleaseCommandSpec: Equatable {
    let command: String
    let description: String
}

/// Secret-free metadata describing the PGYER upload: which artifact, to which endpoint, with what
/// optional build note. The API key is **never** stored here (I3) — it is passed to
/// `configFileBody(apiKey:)` only at spawn time. The coordinator (S29) reads the key from the
/// Keychain, writes the returned body to a 0600 `curl --config` file, then spawns
/// `/usr/bin/curl --config <file> <url>` and deletes the file.
struct PgyerUpload: Equatable {
    /// Absolute path to the produced artifact (`.ipa`/`.dmg`) to upload.
    let artifact: String
    /// The PGYER upload endpoint (non-secret config, `ConfigStore.pgyerUploadURL()`).
    let url: String
    /// Optional per-repo build note (PGYER's update description); nil when the repo sets none.
    let note: String?

    /// The body of the 0600 `curl --config` file, carrying the multipart form fields. The API key
    /// enters here and **only** here (I3): callers hold it just long enough to write the temp file.
    /// The endpoint URL is passed as a curl argument by the coordinator, so it is not repeated here.
    func configFileBody(apiKey: String) -> String {
        var lines = [
            "form = \"_api_key=\(apiKey)\"",
            "form = \"file=@\(artifact)\"",
        ]
        if let note, !note.isEmpty {
            lines.append("form = \"buildUpdateDescription=\(note)\"")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// The full `/release` pipeline: the ordered build `Action`s to run (archive → export, stop on first
/// non-zero exit) followed by the secret-free upload description. Secret-free by construction.
struct ReleasePlan: Equatable {
    let buildSteps: [Action]
    let upload: PgyerUpload
}

/// The outcome of building the `/release` pipeline: the plan to run, or a short, secret-free reason
/// the guard turns into a `⚠️` reply + audit line (nothing spawns).
enum ReleaseResolution: Equatable {
    case ok(ReleasePlan)
    case invalid(reason: String)
}

/// The outcome of building the `/pgyer` upload-only step: the upload metadata, or a refusal.
enum PgyerResolution: Equatable {
    case ok(PgyerUpload)
    case invalid(reason: String)
}

enum ReleaseCommand {
    /// xcodebuild archive/export are slow (minutes on a clean tree); reuse the `/sim` build timeout.
    private static let buildTimeout: TimeInterval = 1800

    /// The canonical `/release` spec — the value production injects into the guard and advertises.
    static let spec = ReleaseCommandSpec(
        command: "/release",
        description: "Archive, export & upload the active repo to PGYER")

    /// The canonical `/pgyer` spec — upload the configured artifact only, without a rebuild.
    static let pgyerSpec = ReleaseCommandSpec(
        command: "/pgyer",
        description: "Upload the active repo's configured artifact to PGYER")

    /// Builds the full `/release` pipeline (archive → export + upload) from the active repo's config,
    /// or refuses if any required field is missing. Every token comes only from `repo` + `uploadURL`
    /// (I1); each build step runs in the repo's root and is tagged with the `/release` token.
    static func plan(for repo: RepoConfig, uploadURL: String) -> ReleaseResolution {
        // §4c: refuse (nothing spawns) unless every value the pipeline needs is configured. Missing
        // fields can only ever narrow what `/release` reaches — never widen it — so this fails closed.
        guard let workspace = repo.workspace, !workspace.isEmpty else {
            return .invalid(reason: "no workspace configured for this repo")
        }
        guard let scheme = repo.scheme, !scheme.isEmpty else {
            return .invalid(reason: "no scheme configured for this repo")
        }
        guard let plist = repo.exportOptionsPlist, !plist.isEmpty else {
            return .invalid(reason: "no export options plist configured for this repo")
        }
        // Reuse the `/pgyer` builder for the artifact check + resolution, propagating its refusal so
        // the two paths never diverge on what counts as a valid upload.
        let upload: PgyerUpload
        switch self.upload(for: repo, uploadURL: uploadURL) {
        case .invalid(let reason): return .invalid(reason: reason)
        case .ok(let resolved): upload = resolved
        }

        // Fixed per-repo output layout: archive + export write under a derived `build/` dir (§4c).
        let archivePath = buildPath(repo.root, "build", "\(scheme).xcarchive")
        let exportPath = buildPath(repo.root, "build")

        func step(_ description: String, _ arguments: [String]) -> Action {
            Action(command: spec.command, description: description, executable: "/usr/bin/xcodebuild",
                   arguments: arguments, timeout: buildTimeout, workingDirectory: repo.root)
        }

        return .ok(ReleasePlan(
            buildSteps: [
                // 1) Archive the app for device. Variable values from config; -sdk/-configuration fixed.
                step("Archive the app",
                     ["archive",
                      "-workspace", workspace,
                      "-scheme", scheme,
                      "-archivePath", archivePath,
                      "-sdk", "iphoneos",
                      "-configuration", "Release"]),
                // 2) Export the archive to an `.ipa` in the build/ dir using the configured plist.
                step("Export the archive",
                     ["-exportArchive",
                      "-archivePath", archivePath,
                      "-exportOptionsPlist", plist,
                      "-exportPath", exportPath]),
            ],
            upload: upload))
    }

    /// Builds the `/pgyer` upload-only step from the active repo's config. Requires only the
    /// `uploadArtifact` (a pre-built `.ipa`/`.dmg` needs no rebuild); the endpoint comes from config,
    /// the note from the repo. Refuses (nothing spawns) when no artifact is configured.
    static func upload(for repo: RepoConfig, uploadURL: String) -> PgyerResolution {
        guard let artifact = repo.uploadArtifact, !artifact.isEmpty else {
            return .invalid(reason: "no upload artifact configured for this repo")
        }
        let note = repo.pgyerDescription.flatMap { $0.isEmpty ? nil : $0 }
        return .ok(PgyerUpload(artifact: resolve(repo.root, artifact), url: uploadURL, note: note))
    }

    /// Joins a repo root with path components, normalizing a trailing slash so argv is deterministic.
    private static func buildPath(_ root: String, _ components: String...) -> String {
        var base = root
        while base.hasSuffix("/") { base.removeLast() }
        return ([base] + components).joined(separator: "/")
    }

    /// Resolves a configured artifact path against the repo root. An already-absolute path is used
    /// as-is; a relative one (e.g. `build/App.ipa`) is joined under the root so curl's `file=@` gets
    /// an absolute path regardless of the spawn cwd.
    private static func resolve(_ root: String, _ artifact: String) -> String {
        artifact.hasPrefix("/") ? artifact : buildPath(root, artifact)
    }
}
