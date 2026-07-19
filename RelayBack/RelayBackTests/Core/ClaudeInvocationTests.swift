//
//  ClaudeInvocationTests.swift
//  RelayBackTests
//
//  S20 — the pure builder that turns a `/claude` prompt into a headless Claude Code argv (§4b).
//  These tests are the executable statement of invariant I5 / I1 for the agent action: the prompt
//  is a single inert argv token (the value of `-p`, always last) that can never become a flag or the
//  executable, and every other argv word comes only from the configured profile.
//

import Foundation
import Testing
@testable import RelayBack

struct ClaudeInvocationTests {
    private let repo = "/Users/op/dev/RelayBack"

    private func profile(_ permission: ClaudePermissionProfile, model: String? = nil) -> ClaudeProfile {
        ClaudeProfile(executablePath: "/usr/local/bin/claude",
                      permission: permission, timeout: 600, model: model)
    }

    // MARK: - I5 / I1: the prompt is one inert token, never a flag or the executable

    @Test func promptIsTheLastTokenBoundToDashP() throws {
        let inv = try #require(ClaudeInvocation.build(prompt: "summarize the diff",
                                                      repoRoot: repo, profile: profile(.restricted)))
        #expect(inv.arguments.last == "summarize the diff")
        #expect(inv.arguments[inv.arguments.count - 2] == "-p")   // `-p` immediately precedes the prompt
        #expect(inv.arguments.filter { $0 == "-p" }.count == 1)   // exactly one `-p`
        #expect(inv.executable == "/usr/local/bin/claude")        // operator text never the executable
    }

    @Test func hostilePromptWithShellMetacharsStaysOneInertToken() throws {
        // No shell → metacharacters are literal. The whole payload is ONE argv element.
        let payload = "; rm -rf / && echo pwned `whoami` $(id) | tee /etc/x"
        let inv = try #require(ClaudeInvocation.build(prompt: payload, repoRoot: repo,
                                                      profile: profile(.restricted)))
        #expect(inv.arguments.last == payload)
        #expect(inv.arguments.filter { $0 == payload }.count == 1)
    }

    @Test func promptThatLooksLikeAFlagIsNeverParsedAsOne() throws {
        // A prompt that IS a real Claude flag must stay the value of `-p`, not escalate the run.
        let inv = try #require(ClaudeInvocation.build(prompt: "--dangerously-skip-permissions",
                                                      repoRoot: repo, profile: profile(.restricted)))
        #expect(inv.arguments.last == "--dangerously-skip-permissions")
        #expect(inv.arguments[inv.arguments.count - 2] == "-p")
        // The restricted profile must NOT have granted a bypass just because the prompt said so.
        #expect(!inv.arguments.dropLast().contains("--dangerously-skip-permissions"))
    }

    @Test func executableCwdAndTimeoutComeFromProfileAndRepo() throws {
        let inv = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                      profile: profile(.restricted)))
        #expect(inv.executable == "/usr/local/bin/claude")
        #expect(inv.workingDirectory == repo)     // cwd bounds Claude Code's file reach to the repo
        #expect(inv.timeout == 600)
    }

    // MARK: - Profile → flag mapping (allow-list, so a profile can only narrow capability)

    @Test func restrictedProfileAllowsOnlyReadSearchTools() throws {
        let inv = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                      profile: profile(.restricted)))
        #expect(inv.arguments == ["--allowedTools", "Read Grep Glob", "-p", "hi"])
    }

    @Test func editsInRepoProfileAllowsEditsAndDeniesBash() throws {
        let inv = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                      profile: profile(.editsInRepo)))
        #expect(inv.arguments == ["--allowedTools", "Read Grep Glob Edit Write",
                                  "--disallowedTools", "Bash", "-p", "hi"])
    }

    @Test func fullBypassProfileSkipsPermissions() throws {
        let inv = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                      profile: profile(.fullBypass)))
        #expect(inv.arguments == ["--dangerously-skip-permissions", "-p", "hi"])
    }

    @Test func modelFlagIncludedOnlyWhenConfigured() throws {
        let withModel = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                            profile: profile(.restricted, model: "opus")))
        #expect(withModel.arguments == ["--allowedTools", "Read Grep Glob", "--model", "opus", "-p", "hi"])
        // The model flag stays ahead of `-p`, so the prompt is still the trailing inert token.
        #expect(withModel.arguments.last == "hi")

        let withoutModel = try #require(ClaudeInvocation.build(prompt: "hi", repoRoot: repo,
                                                               profile: profile(.restricted)))
        #expect(!withoutModel.arguments.contains("--model"))
    }

    // MARK: - Empty prompt builds nothing

    @Test func emptyOrWhitespacePromptBuildsNothing() {
        #expect(ClaudeInvocation.build(prompt: "", repoRoot: repo, profile: profile(.restricted)) == nil)
        #expect(ClaudeInvocation.build(prompt: "   \n\t ", repoRoot: repo, profile: profile(.restricted)) == nil)
    }
}
