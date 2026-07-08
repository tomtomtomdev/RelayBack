//
//  ParameterizedActionResolver.swift
//  RelayBack
//
//  S15 — the mechanism for parameterized dev-workflow actions (§4a), with NO user-facing command
//  wired yet: production configures an empty set, so nothing new is matchable (proven by tests).
//  The S16+ slices add the actual `ParameterizedCommand` specs (git/xcodebuild/simctl) and the
//  repo table; this type is the single place a spec + operator tokens becomes a runnable `Action`.
//
//  Invariant I1 is preserved by construction: the `executable` and the leading `fixedArgs` come
//  ONLY from the (fixed, in-code) spec — never from operator text — and each operator token is
//  validated by `ParamValidator` before it is appended at a fixed argv index. A value-bearing arg
//  is expected to sit behind a `--` guard carried in `fixedArgs` (e.g. `checkout --`) so it can
//  never be read as a flag even if a validator ever loosened. A repo-name parameter resolves to an
//  absolute root from the configured allowlist and becomes the working directory — it is not argv.
//

import Foundation

/// One validated parameter slot of a parameterized command. Each maps one operator token.
enum ParamKind: Equatable {
    /// A configured repo name → resolves to that repo's absolute root (sets the working directory).
    case repoName
    /// A git branch/ref name → one validated argv token.
    case branch
    /// A commit message → one validated argv token (may contain spaces; it is a single token).
    case commitMessage
}

/// A parameterized dev-workflow command: a fixed executable + fixed leading argv, followed by an
/// ordered list of validated parameter slots. Everything except the operator-supplied parameter
/// values is fixed in code (§4a / I1).
struct ParameterizedCommand: Equatable {
    /// The command token that selects this command, including the leading slash (e.g. "/checkout").
    let command: String
    /// Human-readable description (for menus / `setMyCommands`).
    let description: String
    /// Absolute path to the executable. Never derived from operator text.
    let executable: String
    /// Fixed leading arguments (e.g. `["checkout", "--"]`). Never derived from operator text; a
    /// trailing `--` here is the flag guard for a following value parameter.
    let fixedArgs: [String]
    /// The ordered operator-supplied parameter slots that follow `fixedArgs`.
    let parameters: [ParamKind]
    /// Wall-clock limit for the spawned process.
    let timeout: TimeInterval
}

/// The outcome of resolving a command + tokens: a ready-to-run `Action`, or a short, secret-free
/// reason the coordinator turns into a `⚠️` reply + audit line (nothing spawns).
enum ParameterResolution: Equatable {
    case ok(Action)
    case invalid(reason: String)
}

enum ParameterizedActionResolver {
    /// Validates each operator token against its slot and builds the fixed argv, or refuses.
    /// `argTokens` are the operator-supplied values in slot order (a repo-name/branch token has no
    /// spaces; a commit message is a single token that may contain spaces). `repoTable` maps a
    /// configured repo name to its absolute root.
    static func resolve(_ spec: ParameterizedCommand,
                        argTokens: [String],
                        repoTable: [String: String]) -> ParameterResolution {
        guard argTokens.count == spec.parameters.count else {
            return .invalid(reason: argTokens.count < spec.parameters.count
                            ? "missing parameter"
                            : "unexpected extra input")
        }

        var valueArgs: [String] = []
        var workingDirectory: String?

        for (kind, token) in zip(spec.parameters, argTokens) {
            switch kind {
            case .repoName:
                guard let root = ParamValidator.repoName(token, in: repoTable) else {
                    return .invalid(reason: "unknown repo")
                }
                workingDirectory = root          // selects a directory, not an argv token (§4a)
            case .branch:
                guard ParamValidator.branch(token) else {
                    return .invalid(reason: "invalid branch name")
                }
                valueArgs.append(token)
            case .commitMessage:
                guard ParamValidator.commitMessage(token) else {
                    return .invalid(reason: "invalid commit message")
                }
                valueArgs.append(token)
            }
        }

        let action = Action(command: spec.command,
                            description: spec.description,
                            executable: spec.executable,
                            arguments: spec.fixedArgs + valueArgs,   // I1: fixed argv + validated values
                            timeout: spec.timeout,
                            workingDirectory: workingDirectory)
        return .ok(action)
    }
}
