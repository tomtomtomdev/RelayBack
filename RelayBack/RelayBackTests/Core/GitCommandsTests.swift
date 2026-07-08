//
//  GitCommandsTests.swift
//  RelayBackTests
//
//  S17 — the production git command specs (§4a dev-workflow epic). The resolver/validator/active-
//  repo mechanism is already proven (S15/S16); this slice pins the actual `/usr/bin/git` specs:
//  each is repo-scoped, names a fixed executable + fixed leading argv, and only a validated operator
//  value ever lands at a fixed argv index (I1). The final test is the PLAN-mandated real smoke:
//  `/gitstatus` returns exit 0 in a throwaway git repo (the one real-process exception CLAUDE grants
//  — short-lived, local `git`).
//

import Foundation
import Testing
@testable import RelayBack

struct GitCommandsTests {

    /// The git specs never touch a repo table — a repo is the working directory the guard injects,
    /// never an argv token — so resolution needs only an empty table.
    private func resolve(_ command: String, _ argTokens: [String]) -> ParameterResolution {
        let spec = GitCommands.all.first { $0.command == command }!
        return ParameterizedActionResolver.resolve(spec, argTokens: argTokens, repoTable: [:])
    }

    private func action(_ command: String, _ argTokens: [String] = []) -> Action? {
        guard case let .ok(action) = resolve(command, argTokens) else { return nil }
        return action
    }

    // MARK: - Every git command is repo-scoped and spawns only /usr/bin/git (I1 / §4a)

    @Test func everyCommandIsRepoScopedGitOnly() {
        #expect(!GitCommands.all.isEmpty)
        for spec in GitCommands.all {
            #expect(spec.requiresActiveRepo)             // §4a: runs in the active repo, /cd first
            #expect(spec.executable == "/usr/bin/git")   // I1: fixed absolute executable
            #expect(spec.command.hasPrefix("/"))
        }
        // The full set the PLAN scopes for S17.
        let commands = Set(GitCommands.all.map(\.command))
        #expect(commands == ["/gitstatus", "/branch", "/checkout", "/pull", "/push", "/commit"])
    }

    // MARK: - Each command builds the exact fixed argv

    @Test func gitStatusBuildsStatusArgv() {
        #expect(action("/gitstatus")?.arguments == ["status"])
    }

    @Test func branchBuildsBranchArgv() {
        #expect(action("/branch")?.arguments == ["branch"])
    }

    @Test func checkoutBuildsCheckoutArgvWithTheValidatedBranch() {
        // `git checkout <branch>` — the validated branch is a single argv token. No `--` guard: it
        // would force pathspec interpretation and break the branch switch; the leading-`-` rejection
        // in ParamValidator.branch is the real flag-injection guard (§4a).
        #expect(action("/checkout", ["feature/login"])?.arguments == ["checkout", "feature/login"])
    }

    @Test func pullBuildsFastForwardOnlyArgv() {
        #expect(action("/pull")?.arguments == ["pull", "--ff-only"])
    }

    @Test func pushBuildsBarePushArgv() {
        // Upstream-only: no remote/refspec argument is ever built, so a push can only go to the
        // current branch's configured upstream (§4a / SPEC).
        #expect(action("/push")?.arguments == ["push"])
    }

    @Test func commitBuildsCommitArgvWithTheMessageAsASingleToken() {
        #expect(action("/commit", ["fix the login crash"])?.arguments
                == ["commit", "-a", "-m", "fix the login crash"])
    }

    // MARK: - Operator input is validated / refused; nothing is built on bad input

    @Test func checkoutRejectsBranchWithMetacharactersOrLeadingDash() {
        #expect(resolve("/checkout", ["-x"]) == .invalid(reason: "invalid branch name"))
        #expect(resolve("/checkout", ["a; rm -rf /"]) == .invalid(reason: "invalid branch name"))
    }

    @Test func pushAndPullAcceptNoOperatorArguments() {
        // A zero-parameter command must reject trailing operator input — /push must never take a
        // remote/refspec, /pull must never take a remote/branch.
        #expect(resolve("/push", ["origin"]) == .invalid(reason: "unexpected extra input"))
        #expect(resolve("/pull", ["origin main"]) == .invalid(reason: "unexpected extra input"))
    }

    @Test func commitRejectsLeadingDashMessageAndCapsLength() {
        #expect(resolve("/commit", ["-m evil"]) == .invalid(reason: "invalid commit message"))
        let tooLong = String(repeating: "a", count: ParamValidator.maxCommitMessageLength + 1)
        #expect(resolve("/commit", [tooLong]) == .invalid(reason: "invalid commit message"))
    }

    @Test func commitRequiresAMessage() {
        #expect(resolve("/commit", []) == .invalid(reason: "missing parameter"))
    }

    // MARK: - Real smoke: /gitstatus returns exit 0 in a throwaway repo (PLAN done-when)

    @Test func gitStatusRunsExitZeroInARealRepo() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("relayback-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Scaffolding: initialise a real repo in the temp dir (a plain Process, not the run path).
        let initProc = Process()
        initProc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        initProc.arguments = ["init"]
        initProc.currentDirectoryURL = temp
        try initProc.run()
        initProc.waitUntilExit()
        try #require(initProc.terminationStatus == 0)

        // The production path: resolve the /gitstatus spec, inject the repo root as the guard does,
        // and run it through the real runner. It must succeed.
        guard let base = action("/gitstatus") else { return #expect(Bool(false), "expected .ok") }
        let result = await ProcessCommandRunner().run(base.withWorkingDirectory(temp.path))
        #expect(result.exitCode == 0)
    }
}
