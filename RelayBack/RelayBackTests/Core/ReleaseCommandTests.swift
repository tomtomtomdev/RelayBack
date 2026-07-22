//
//  ReleaseCommandTests.swift
//  RelayBackTests
//
//  S28 — the pure `/release` + `/pgyer` builder (§4c release-&-distribution epic). Like `/sim`,
//  `/release` resolves to an ordered SEQUENCE of `Action`s (archive → export) built entirely from
//  the active repo's `RepoConfig` + the configured endpoint URL — never operator text, never argv
//  the operator can influence (I1). The upload is described by secret-free `PgyerUpload` metadata;
//  the PGYER API key is NEVER part of the plan — it is folded into `configFileBody(apiKey:)` only at
//  spawn time (I3). This slice pins the exact archive/export argv from config, the derived `build/`
//  layout, every missing-field rejection (fail closed), the config-file body form fields, and the
//  I3-at-the-builder guarantee that no key can appear in the returned plan.
//
//  No real xcodebuild/curl runs here — argv + metadata only (PLAN S28); guard routing + the real
//  0600 `--config` write land in S29.
//

import Foundation
import Testing
@testable import RelayBack

struct ReleaseCommandTests {

    /// A fully-configured release repo, and repos each missing one required field.
    private var configured: RepoConfig {
        RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                   scheme: "RelayBack",
                   workspace: "RelayBack.xcworkspace",
                   exportOptionsPlist: "ExportOptions.plist",
                   uploadArtifact: "build/RelayBack.ipa",
                   pgyerDescription: "nightly build")
    }
    private var noWorkspace: RepoConfig {
        RepoConfig(name: "a", root: "/Users/op/dev/A",
                   scheme: "A", exportOptionsPlist: "E.plist", uploadArtifact: "build/A.ipa")
    }
    private var noScheme: RepoConfig {
        RepoConfig(name: "b", root: "/Users/op/dev/B",
                   workspace: "B.xcworkspace", exportOptionsPlist: "E.plist",
                   uploadArtifact: "build/B.ipa")
    }
    private var noPlist: RepoConfig {
        RepoConfig(name: "c", root: "/Users/op/dev/C",
                   scheme: "C", workspace: "C.xcworkspace", uploadArtifact: "build/C.ipa")
    }
    private var noArtifact: RepoConfig {
        RepoConfig(name: "d", root: "/Users/op/dev/D",
                   scheme: "D", workspace: "D.xcworkspace", exportOptionsPlist: "E.plist")
    }

    private let url = "https://www.pgyer.com/apiv2/app/upload"

    // MARK: - The specs are the `/release` + `/pgyer` command tokens (for matching / advertising)

    @Test func specIsTheReleaseCommandToken() {
        #expect(ReleaseCommand.spec.command == "/release")
        #expect(!ReleaseCommand.spec.description.isEmpty)
    }

    @Test func pgyerSpecIsTheUploadOnlyToken() {
        #expect(ReleaseCommand.pgyerSpec.command == "/pgyer")
        #expect(!ReleaseCommand.pgyerSpec.description.isEmpty)
    }

    // MARK: - /release builds the archive → export argv SEQUENCE from config, never chat (I1)

    @Test func buildsArchiveThenExportSequenceFromConfig() {
        guard case let .ok(plan) = ReleaseCommand.plan(for: configured, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(plan.buildSteps.count == 2)

        // Step 1 — archive with the repo's fixed workspace/scheme + a derived build/ archive path;
        //          `-sdk iphoneos -configuration Release` are fixed in code (§4c).
        #expect(plan.buildSteps[0].executable == "/usr/bin/xcodebuild")
        #expect(plan.buildSteps[0].arguments ==
                ["archive",
                 "-workspace", "RelayBack.xcworkspace",
                 "-scheme", "RelayBack",
                 "-archivePath", "/Users/op/dev/RelayBack/build/RelayBack.xcarchive",
                 "-sdk", "iphoneos",
                 "-configuration", "Release"])

        // Step 2 — export the archive to the derived build/ dir using the configured plist.
        #expect(plan.buildSteps[1].executable == "/usr/bin/xcodebuild")
        #expect(plan.buildSteps[1].arguments ==
                ["-exportArchive",
                 "-archivePath", "/Users/op/dev/RelayBack/build/RelayBack.xcarchive",
                 "-exportOptionsPlist", "ExportOptions.plist",
                 "-exportPath", "/Users/op/dev/RelayBack/build"])
    }

    // MARK: - Every build step runs in the active repo root, tagged with the /release token (I1/I4)

    @Test func everyBuildStepRunsInTheRepoRootAsRelease() {
        guard case let .ok(plan) = ReleaseCommand.plan(for: configured, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(plan.buildSteps.allSatisfy { $0.workingDirectory == "/Users/op/dev/RelayBack" })
        #expect(plan.buildSteps.allSatisfy { $0.command == "/release" })
        // I1/I4: only fixed absolute executables are ever spawned — no operator text reaches the slot.
        #expect(plan.buildSteps.allSatisfy { $0.executable.hasPrefix("/usr/bin/") })
    }

    // MARK: - The upload metadata is built from config (artifact resolved under the repo root)

    @Test func releaseUploadMetadataComesFromConfig() {
        guard case let .ok(plan) = ReleaseCommand.plan(for: configured, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(plan.upload == PgyerUpload(
            artifact: "/Users/op/dev/RelayBack/build/RelayBack.ipa",
            url: url,
            note: "nightly build"))
    }

    // MARK: - A repo missing any required release field is refused — nothing is built (fail closed)

    @Test func rejectsRepoWithNoWorkspace() {
        #expect(ReleaseCommand.plan(for: noWorkspace, uploadURL: url)
                == .invalid(reason: "no workspace configured for this repo"))
    }

    @Test func rejectsRepoWithNoScheme() {
        #expect(ReleaseCommand.plan(for: noScheme, uploadURL: url)
                == .invalid(reason: "no scheme configured for this repo"))
    }

    @Test func rejectsRepoWithNoExportOptionsPlist() {
        #expect(ReleaseCommand.plan(for: noPlist, uploadURL: url)
                == .invalid(reason: "no export options plist configured for this repo"))
    }

    @Test func rejectsRepoWithNoUploadArtifact() {
        #expect(ReleaseCommand.plan(for: noArtifact, uploadURL: url)
                == .invalid(reason: "no upload artifact configured for this repo"))
    }

    // MARK: - /pgyer builds the upload only (no rebuild), requiring just the artifact

    @Test func pgyerBuildsUploadOnlyFromConfig() {
        guard case let .ok(upload) = ReleaseCommand.upload(for: configured, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(upload == PgyerUpload(
            artifact: "/Users/op/dev/RelayBack/build/RelayBack.ipa",
            url: url,
            note: "nightly build"))
    }

    @Test func pgyerNeedsOnlyTheArtifact() {
        // A repo with an artifact but no workspace/scheme/plist can still upload a pre-built file.
        let uploadOnly = RepoConfig(name: "u", root: "/Users/op/dev/U",
                                    uploadArtifact: "dist/U.dmg")
        guard case let .ok(upload) = ReleaseCommand.upload(for: uploadOnly, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        #expect(upload.artifact == "/Users/op/dev/U/dist/U.dmg")
        #expect(upload.note == nil)
    }

    @Test func pgyerRejectsRepoWithNoUploadArtifact() {
        #expect(ReleaseCommand.upload(for: noArtifact, uploadURL: url)
                == .invalid(reason: "no upload artifact configured for this repo"))
    }

    // MARK: - configFileBody carries the key + form fields (the key enters ONLY here, at spawn time)

    @Test func configFileBodyCarriesKeyAndFormFields() {
        let upload = PgyerUpload(artifact: "/Users/op/dev/RelayBack/build/RelayBack.ipa",
                                 url: url, note: "nightly build")
        let body = upload.configFileBody(apiKey: "SECRET-KEY-123")

        // The key rides in a `form` field (multipart `_api_key`), never in argv (I3).
        #expect(body.contains("form = \"_api_key=SECRET-KEY-123\""))
        // The artifact is uploaded as a multipart file.
        #expect(body.contains("form = \"file=@/Users/op/dev/RelayBack/build/RelayBack.ipa\""))
        // The per-repo build note becomes PGYER's update description.
        #expect(body.contains("form = \"buildUpdateDescription=nightly build\""))
    }

    @Test func configFileBodyOmitsNoteWhenAbsent() {
        let upload = PgyerUpload(artifact: "/Users/op/dev/U/dist/U.dmg", url: url, note: nil)
        let body = upload.configFileBody(apiKey: "K")
        #expect(body.contains("form = \"_api_key=K\""))
        #expect(!body.contains("buildUpdateDescription"))
    }

    // MARK: - I3 at the builder: the returned plan is SECRET-FREE — no key can appear in it

    @Test func planNeverCarriesTheApiKey() {
        // The builder takes no key at all, so nothing it returns can hold one. Assert structurally:
        // scan every string reachable from the plan for a sentinel that only `configFileBody` sees.
        guard case let .ok(plan) = ReleaseCommand.plan(for: configured, uploadURL: url) else {
            return #expect(Bool(false), "expected .ok")
        }
        let sentinel = "SECRET-KEY-123"
        var reachable = plan.upload.artifact + plan.upload.url + (plan.upload.note ?? "")
        for step in plan.buildSteps {
            reachable += step.executable + step.arguments.joined() + (step.workingDirectory ?? "")
        }
        #expect(!reachable.contains(sentinel))
        // And the key only ever materializes when explicitly folded in at spawn time.
        #expect(plan.upload.configFileBody(apiKey: sentinel).contains(sentinel))
    }
}
