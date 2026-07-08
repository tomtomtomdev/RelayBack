//
//  GitCommands.swift
//  RelayBack
//
//  S17 — the production set of parameterized git commands (§4a dev-workflow epic). Each is a fixed
//  `/usr/bin/git` invocation with a fixed leading argv; only a validated operator value (a branch
//  name, a commit message) ever lands at a fixed argv index, and the working directory is the
//  session's active repo (never operator text). This is data only — the resolver/validator/active-
//  repo mechanism (S15/S16) turns a matched command + tokens into a runnable `Action`.
//
//  Invariant I1 (no shell, ever): the executable and every fixed arg here are in-code constants;
//  operator input is confined to the validated `.branch` / `.commitMessage` slots. I4: the runner
//  spawns `/usr/bin/git` as the normal user under a restricted PATH.
//
//  Deviation from PLAN S17: `/checkout` builds `git checkout <branch>`, NOT `checkout -- <branch>`.
//  A `--` forces git to read the following token as a *pathspec*, so `checkout -- main` would try to
//  restore a file named "main" rather than switch to the branch — the command would never work. The
//  leading-`-` rejection in `ParamValidator.branch` is the real flag-injection guard (per S15), so
//  dropping the redundant `--` costs no safety and restores correct branch-switch semantics.
//

import Foundation

enum GitCommands {
    /// Local git operations (status/branch/checkout/commit) — fast, no network.
    private static let localTimeout: TimeInterval = 30
    /// Network git operations (pull/push) — allow for a slow remote.
    private static let networkTimeout: TimeInterval = 120

    /// The six git commands the PLAN scopes for S17, each repo-scoped (`requiresActiveRepo`) so it
    /// runs in the session's active repo root, selected with `/cd <repo>` first.
    static let all: [ParameterizedCommand] = [
        ParameterizedCommand(
            command: "/gitstatus", description: "Working tree status",
            executable: "/usr/bin/git", fixedArgs: ["status"],
            parameters: [], timeout: localTimeout, requiresActiveRepo: true),
        ParameterizedCommand(
            command: "/branch", description: "List branches",
            executable: "/usr/bin/git", fixedArgs: ["branch"],
            parameters: [], timeout: localTimeout, requiresActiveRepo: true),
        ParameterizedCommand(
            command: "/checkout", description: "Switch branch",
            executable: "/usr/bin/git", fixedArgs: ["checkout"],
            parameters: [.branch], timeout: localTimeout, requiresActiveRepo: true),
        ParameterizedCommand(
            command: "/pull", description: "Fast-forward pull from upstream",
            executable: "/usr/bin/git", fixedArgs: ["pull", "--ff-only"],
            parameters: [], timeout: networkTimeout, requiresActiveRepo: true),
        ParameterizedCommand(
            command: "/push", description: "Push to the current branch's upstream",
            executable: "/usr/bin/git", fixedArgs: ["push"],
            parameters: [], timeout: networkTimeout, requiresActiveRepo: true),
        ParameterizedCommand(
            command: "/commit", description: "Commit all tracked changes",
            executable: "/usr/bin/git", fixedArgs: ["commit", "-a", "-m"],
            parameters: [.commitMessage], timeout: localTimeout, requiresActiveRepo: true),
    ]
}
