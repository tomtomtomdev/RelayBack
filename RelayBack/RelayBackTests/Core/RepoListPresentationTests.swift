//
//  RepoListPresentationTests.swift
//  RelayBackTests
//
//  S16 — the pure `/repos` and `/pwd` reply text. The security-relevant property is disclosure:
//  only a repo's name and root may reach chat; the internal build config (scheme / destination /
//  simulatorDevice) must never leak. These assert that directly.
//

import Foundation
import Testing
@testable import RelayBack

struct RepoListPresentationTests {

    // A repo whose build-config fields carry distinctive sentinels a leak would surface.
    private let full = RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                                  scheme: "SCHEME_SENTINEL", destination: "DEST_SENTINEL",
                                  simulatorDevice: "SIM_SENTINEL")

    @Test func listShowsNameAndRootOnly() {
        let text = RepoListPresentation.list([full])
        #expect(text.contains("relayback"))
        #expect(text.contains("/Users/op/dev/RelayBack"))
        // No build-config field is ever disclosed.
        #expect(!text.contains("SCHEME_SENTINEL"))
        #expect(!text.contains("DEST_SENTINEL"))
        #expect(!text.contains("SIM_SENTINEL"))
    }

    @Test func listWithMultipleReposIncludesEachNameAndRoot() {
        let text = RepoListPresentation.list([
            full,
            RepoConfig(name: "notes", root: "/Users/op/dev/Notes"),
        ])
        #expect(text.contains("relayback") && text.contains("/Users/op/dev/RelayBack"))
        #expect(text.contains("notes") && text.contains("/Users/op/dev/Notes"))
    }

    @Test func emptyListSaysSo() {
        #expect(RepoListPresentation.list([]) == "No repos configured.")
    }

    @Test func pwdWithNoActiveRepoPrompts() {
        #expect(RepoListPresentation.pwd(nil) == "No active repo — send /cd <repo> first.")
    }

    @Test func pwdShowsActiveRepoNameAndRootWithoutLeakingConfig() {
        let text = RepoListPresentation.pwd(full)
        #expect(text.contains("relayback") && text.contains("/Users/op/dev/RelayBack"))
        #expect(!text.contains("SCHEME_SENTINEL"))
        #expect(!text.contains("DEST_SENTINEL"))
        #expect(!text.contains("SIM_SENTINEL"))
    }

    // S25: the /cd picker button labels are the repo NAMES only — one per repo, in order — and
    // disclose neither the root nor any build-config field (even less than /repos shows).
    @Test func pickerButtonsAreRepoNamesInOrderOnly() {
        let buttons = RepoListPresentation.pickerButtons([
            full,
            RepoConfig(name: "notes", root: "/Users/op/dev/Notes"),
        ])
        #expect(buttons == ["relayback", "notes"])
        #expect(!buttons.contains { $0.contains("/Users/op/dev/RelayBack") })   // no root leaked
        #expect(!buttons.contains { $0.contains("SCHEME_SENTINEL") })
        #expect(!buttons.contains { $0.contains("DEST_SENTINEL") })
        #expect(!buttons.contains { $0.contains("SIM_SENTINEL") })
    }
}
