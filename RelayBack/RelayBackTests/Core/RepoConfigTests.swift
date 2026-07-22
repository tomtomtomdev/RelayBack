//
//  RepoConfigTests.swift
//  RelayBackTests
//
//  S27 — `RepoConfig` gained four optional release/distribution fields (§4c: `workspace`,
//  `exportOptionsPlist`, `uploadArtifact`, `pgyerDescription`). These pin the Codable contract:
//  the new fields round-trip, and — critically — an OLD persisted blob written before S27 (with
//  none of the new keys) still decodes, with the new fields nil. Backward-compat matters because
//  repos are persisted as JSON in UserDefaults (S16); a blob from a prior version must not fail to
//  decode and silently wipe the operator's repo allowlist.
//

import Foundation
import Testing
@testable import RelayBack

struct RepoConfigTests {

    @Test func newReleaseFieldsRoundTripThroughJSON() throws {
        let repo = RepoConfig(
            name: "relayback", root: "/Users/op/dev/RelayBack",
            scheme: "RelayBack", destination: "platform=iOS Simulator,name=iPhone 15",
            simulatorDevice: "iPhone 15",
            workspace: "RelayBack.xcworkspace",
            exportOptionsPlist: "ExportOptions.plist",
            uploadArtifact: "build/RelayBack.ipa",
            pgyerDescription: "nightly")

        let data = try JSONEncoder().encode(repo)
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: data)

        #expect(decoded == repo)
        #expect(decoded.workspace == "RelayBack.xcworkspace")
        #expect(decoded.exportOptionsPlist == "ExportOptions.plist")
        #expect(decoded.uploadArtifact == "build/RelayBack.ipa")
        #expect(decoded.pgyerDescription == "nightly")
    }

    // A blob written before S27 has only the S16 keys. It must still decode, with every new field
    // nil, so a version upgrade never drops the operator's persisted repos.
    @Test func preS27BlobDecodesWithNewFieldsNil() throws {
        let oldJSON = """
        {"name":"legacy","root":"/Users/op/dev/Legacy","scheme":"Legacy",\
        "destination":"platform=macOS","simulatorDevice":"iPhone 15"}
        """
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: Data(oldJSON.utf8))

        #expect(decoded.name == "legacy")
        #expect(decoded.root == "/Users/op/dev/Legacy")
        #expect(decoded.scheme == "Legacy")
        #expect(decoded.workspace == nil)
        #expect(decoded.exportOptionsPlist == nil)
        #expect(decoded.uploadArtifact == nil)
        #expect(decoded.pgyerDescription == nil)
    }

    // The minimal S16 blob (name + root only, all optionals absent) also still decodes.
    @Test func minimalBlobDecodesWithAllOptionalsNil() throws {
        let oldJSON = #"{"name":"notes","root":"/Users/op/dev/Notes"}"#
        let decoded = try JSONDecoder().decode(RepoConfig.self, from: Data(oldJSON.utf8))
        #expect(decoded == RepoConfig(name: "notes", root: "/Users/op/dev/Notes"))
    }
}
