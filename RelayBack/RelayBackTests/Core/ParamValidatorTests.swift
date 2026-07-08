//
//  ParamValidatorTests.swift
//  RelayBackTests
//
//  S15 — the pure parameter validators are the front line of §4a: every operator-supplied token
//  is checked here before it can ever reach a fixed `Process` argv position. Because there is no
//  shell (I1 unchanged), metacharacters carry no meaning — but a value that *begins* with `-`
//  could still be read by the executable as a flag, and a name could try to escape the repo
//  allowlist, so those are the cases these tables pin.
//

import Foundation
import Testing
@testable import RelayBack

struct ParamValidatorTests {

    // MARK: - repoName: allowlist lookup only (no path ever comes from chat → traversal-proof)

    private let repos: [String: String] = ["relayback": "/Users/op/dev/RelayBack",
                                            "notes": "/Users/op/dev/notes"]

    @Test func repoNameResolvesAConfiguredNameToItsRoot() {
        #expect(ParamValidator.repoName("relayback", in: repos) == "/Users/op/dev/RelayBack")
        #expect(ParamValidator.repoName("notes", in: repos) == "/Users/op/dev/notes")
    }

    @Test func repoNameRejectsAnythingNotInTheAllowlist() {
        #expect(ParamValidator.repoName("unknown", in: repos) == nil)
        #expect(ParamValidator.repoName("", in: repos) == nil)
        // Traversal is impossible: a path-like token is simply not a configured key.
        #expect(ParamValidator.repoName("../../etc", in: repos) == nil)
        #expect(ParamValidator.repoName("/Users/op/dev/RelayBack", in: repos) == nil)
        // Lookup is exact — no case-folding, so a mismatch does not silently widen access.
        #expect(ParamValidator.repoName("RelayBack", in: repos) == nil)
    }

    // MARK: - branch: ^[A-Za-z0-9._/-]+$ and must not begin with '-'

    @Test func branchAcceptsWellFormedRefNames() {
        #expect(ParamValidator.branch("main"))
        #expect(ParamValidator.branch("feature/login"))
        #expect(ParamValidator.branch("release-1.2.3"))
        #expect(ParamValidator.branch("hotfix_42"))
    }

    @Test func branchRejectsLeadingDashSoItCannotBecomeAFlag() {
        #expect(!ParamValidator.branch("-x"))
        #expect(!ParamValidator.branch("--force"))
        #expect(!ParamValidator.branch("-"))
    }

    @Test func branchRejectsMetacharactersWhitespaceAndEmpty() {
        #expect(!ParamValidator.branch(""))
        #expect(!ParamValidator.branch("main; rm -rf /"))
        #expect(!ParamValidator.branch("a b"))
        #expect(!ParamValidator.branch("$(whoami)"))
        #expect(!ParamValidator.branch("foo`bar`"))
        #expect(!ParamValidator.branch("a\nb"))
    }

    // MARK: - commitMessage: non-empty, length-capped, must not begin with '-', single line

    @Test func commitMessageAcceptsOrdinaryMessages() {
        #expect(ParamValidator.commitMessage("fix the login crash"))
        #expect(ParamValidator.commitMessage("chore: bump deps (#123)"))
        // Shell metacharacters are harmless without a shell — they are a literal message.
        #expect(ParamValidator.commitMessage("handle ; and && in text"))
    }

    @Test func commitMessageRejectsLeadingDashEmptyAndNewlines() {
        #expect(!ParamValidator.commitMessage(""))
        #expect(!ParamValidator.commitMessage("-m sneaky"))
        #expect(!ParamValidator.commitMessage("--amend"))
        #expect(!ParamValidator.commitMessage("line one\nline two"))
    }

    @Test func commitMessageIsLengthCapped() {
        let atCap = String(repeating: "x", count: 200)
        let overCap = String(repeating: "x", count: 201)
        #expect(ParamValidator.commitMessage(atCap))
        #expect(!ParamValidator.commitMessage(overCap))
    }
}
