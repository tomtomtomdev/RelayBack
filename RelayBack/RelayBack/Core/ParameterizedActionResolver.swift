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

/// A build-config value drawn from the session's **active repo** (§4a / S18) — NEVER operator text.
/// Each emits a fixed flag followed by the repo's configured value at a fixed argv position (e.g.
/// `-scheme <cfg.scheme>`). Because the value comes only from `RepoConfig`, the operator can never
/// influence it (I1); a repo missing the required config makes resolution fail rather than build a
/// partial `xcodebuild` invocation. Consumed by `/build` (S18) and the later `/sim` (S19).
enum RepoConfigArg: Equatable {
    /// Emits `["-scheme", cfg.scheme]`; fails if the active repo has no scheme.
    case scheme
    /// Emits `["-destination", cfg.destination]`; fails if the active repo has no destination.
    case destination
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
    /// Build-config args drawn from the active repo (§4a / S18), emitted BEFORE `fixedArgs` — e.g.
    /// `[.scheme, .destination]` yields `-scheme <cfg.scheme> -destination <cfg.destination>`. Empty
    /// for the git commands (their argv is fully fixed). Never derived from operator text.
    let configArgs: [RepoConfigArg]
    /// The ordered operator-supplied parameter slots that follow `fixedArgs`.
    let parameters: [ParamKind]
    /// Wall-clock limit for the spawned process.
    let timeout: TimeInterval
    /// Whether this command runs in the session's **active repo** (§4a / S16). When true, the guard
    /// requires an active repo (`/cd <repo>` first) and sets the resolved action's working directory
    /// to that repo's root; with no active repo it returns `.invalidParameters("select a repo first")`.
    /// The git/build/sim commands (S17–S19) set this; a repo-agnostic command leaves it false.
    let requiresActiveRepo: Bool

    init(command: String,
         description: String,
         executable: String,
         fixedArgs: [String],
         configArgs: [RepoConfigArg] = [],
         parameters: [ParamKind],
         timeout: TimeInterval,
         requiresActiveRepo: Bool = false) {
        self.command = command
        self.description = description
        self.executable = executable
        self.fixedArgs = fixedArgs
        self.configArgs = configArgs
        self.parameters = parameters
        self.timeout = timeout
        self.requiresActiveRepo = requiresActiveRepo
    }
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
    /// configured repo name to its absolute root. `activeRepo` is the session's active repo (S18):
    /// a spec with `configArgs` draws its scheme/destination from it, refusing if unconfigured.
    static func resolve(_ spec: ParameterizedCommand,
                        argTokens: [String],
                        repoTable: [String: String],
                        activeRepo: RepoConfig? = nil) -> ParameterResolution {
        guard argTokens.count == spec.parameters.count else {
            return .invalid(reason: argTokens.count < spec.parameters.count
                            ? "missing parameter"
                            : "unexpected extra input")
        }

        // Build-config args (§4a / S18): flag + the active repo's configured value. The values come
        // only from `RepoConfig`, never operator text (I1); a repo missing the config is refused.
        var configArgs: [String] = []
        for kind in spec.configArgs {
            switch kind {
            case .scheme:
                guard let scheme = activeRepo?.scheme, !scheme.isEmpty else {
                    return .invalid(reason: "no scheme configured for this repo")
                }
                configArgs += ["-scheme", scheme]
            case .destination:
                guard let destination = activeRepo?.destination, !destination.isEmpty else {
                    return .invalid(reason: "no destination configured for this repo")
                }
                configArgs += ["-destination", destination]
            }
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
                            // I1: config-derived args + fixed argv + validated operator values —
                            // none of which the operator can point at the executable slot.
                            arguments: configArgs + spec.fixedArgs + valueArgs,
                            timeout: spec.timeout,
                            workingDirectory: workingDirectory)
        return .ok(action)
    }
}
