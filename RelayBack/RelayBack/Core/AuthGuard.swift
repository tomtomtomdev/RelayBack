//
//  AuthGuard.swift
//  RelayBack
//
//  S3 — the arm/disarm state machine and the gate for invariant I2.
//
//  I2 (no run unless authorized AND armed): `authorize` returns `.runAction` only when the
//  sender's `from.id` is on the allowlist AND the session is currently armed. Identity is
//  always checked first, against `from.id` (never a chat id). The TOTP secret is held only in
//  memory for `/arm` validation and is never logged or echoed (I3) — that is the coordinator's
//  contract; this type never emits it.
//

import Foundation

/// The outcome of routing one operator message. The coordinator (S8) turns this into a reply
/// and an audit entry; only `.runAction` ever leads to spawning a process.
enum Decision: Equatable {
    /// `from.id` is not on the allowlist — drop silently (invariant I2, FR-2).
    case rejectedUnknownUser
    /// A control command was handled (arm / disarm / status). Never executes an action.
    case control(ControlResult)
    /// Authorized sender requested an action while the session is not armed (invariant I2).
    case disarmed
    /// Authorized sender, armed session, matched action — safe to run (invariant I2).
    case runAction(Action)
    /// Authorized sender, armed session, matched a MULTI-STEP command (§4a / S19 — `/sim`). Carries
    /// the ordered step sequence, built entirely from the active repo's config (never operator text,
    /// I1); the coordinator runs the steps in order and stops on the first non-zero exit.
    case runActionSequence([Action])
    /// Authorized sender, armed session, `/claude` enabled with an active repo (§4b / S21). Carries
    /// the operator's free-text prompt (the ONE free-text parameter — a single inert token, I5), the
    /// active-repo root (the run cwd that bounds Claude Code), and the configured profile. The
    /// coordinator runs it via `ClaudeRunning`; the prompt is NOT validated — it is contained by the
    /// profile + cwd, never by pretending to validate it (§4b).
    case runClaude(prompt: String, repoRoot: String, profile: ClaudeProfile)
    /// Authorized sender, armed session, matched a parameterized command, but a parameter failed
    /// validation (§4a). Carries a short, secret-free reason; nothing is spawned.
    case invalidParameters(String)
    /// Authorized sender, but the text matches no action and no control command.
    case unknownCommand
}

/// The result of a control command.
enum ControlResult: Equatable {
    case armAccepted        // valid TOTP → session now armed
    case armRejected        // missing / invalid TOTP → still disarmed
    case disarmAccepted     // session dropped to disarmed
    case status(isArmed: Bool)
    // S16 — repo navigation (never executes a process; all report/mutate session state):
    case activeRepoSet(RepoConfig)      // /cd <repo> → active repo is now this one
    case workingDirectory(RepoConfig?)  // /pwd → the active repo (nil when none selected)
    case repoList([RepoConfig])         // /repos → the configured repo allowlist
}

struct AuthGuard {
    private var allowlist: Set<Int64>
    private let totpSecret: Data
    private let registry: ActionRegistry
    private let clock: Clock
    private let idleTimeout: TimeInterval

    /// The parameterized dev-workflow commands this guard can route (§4a / S15). Empty in v1
    /// production — the mechanism is present but no such command is matchable — until S16+ wire
    /// the real git/build specs. When a token matches a spec, operator tokens are validated and
    /// resolved to an `Action` by `ParameterizedActionResolver`.
    private let parameterizedCommands: [ParameterizedCommand]

    /// The MULTI-STEP simulator command (§4a / S19 — `/sim`), or nil when not enabled (the default,
    /// so every existing call site and test is unchanged). Production injects `SimulatorCommand.spec`.
    /// When a token matches, the guard builds the step sequence from the active repo via
    /// `SimulatorCommand.steps(for:)` — never operator text (I1).
    private let simulatorCommand: SimulatorCommandSpec?

    /// The configured repo allowlist (§4a working-directory allowlist, S16). Empty in v1 until the
    /// operator adds repos in Settings. `/cd <name>` selects one; git/build/sim commands run in the
    /// selected repo's root. No path ever comes from chat — a name is matched exactly against this.
    /// `var` so a Settings edit can hot-reload it (`updateRepos`).
    private var repoConfigs: [RepoConfig]

    /// Name → absolute root, derived from `repoConfigs`, for a resolver `.repoName` parameter (S15).
    private var repoTable: [String: String] {
        Dictionary(repoConfigs.map { ($0.name, $0.root) }, uniquingKeysWith: { first, _ in first })
    }

    /// End of the armed window; nil means never armed. Armed iff `clock.now < armedUntil`.
    /// Expiry is derived lazily from this instant — no background timer needed (pure type).
    private var armedUntil: Date?

    /// The session's active repo (§4a / S16), selected by `/cd`. Lives with the armed session:
    /// cleared on `/disarm`, on `disarm()`, and when a fresh `/arm` starts a new session, so it
    /// never leaks across sessions. Only meaningful while armed (see `currentRepo`).
    private var activeRepo: RepoConfig?

    /// Whether the `/claude` agent action is enabled (§4b / S21 — invariant I5). **Defaults OFF**, so
    /// every existing call site/test leaves it disabled and `/claude` refuses until the operator opts
    /// in (S22). This is the capability half of the I5 gate (the arm gate + active-repo are the rest).
    private let claudeEnabled: Bool

    /// The Claude Code profile (executable, permission posture, timeout, model) carried in a
    /// `.runClaude` decision for the coordinator's runner. The guard never spawns — it only gates and
    /// packages the run. Fail-closed default (`restricted`, no executable) keeps I5 safe by default.
    private let claudeProfile: ClaudeProfile

    init(allowlist: Set<Int64>,
         totpSecret: Data,
         registry: ActionRegistry,
         clock: Clock,
         idleTimeout: TimeInterval,
         parameterizedCommands: [ParameterizedCommand] = [],
         repoConfigs: [RepoConfig] = [],
         simulatorCommand: SimulatorCommandSpec? = nil,
         claudeEnabled: Bool = false,
         claudeProfile: ClaudeProfile = .default) {
        self.allowlist = allowlist
        self.totpSecret = totpSecret
        self.registry = registry
        self.clock = clock
        self.idleTimeout = idleTimeout
        self.parameterizedCommands = parameterizedCommands
        self.repoConfigs = repoConfigs
        self.simulatorCommand = simulatorCommand
        self.claudeEnabled = claudeEnabled
        self.claudeProfile = claudeProfile
    }

    /// Replaces the authorization allowlist at runtime (S12 — hot-reload from Settings). Arm state
    /// is intentionally preserved: identity and session are orthogonal, so editing who may run
    /// commands must neither drop a legitimate operator's live session nor keep a removed id armed.
    /// A removed id is revoked immediately — its next message fails the identity gate (invariant I2).
    mutating func updateAllowlist(_ ids: Set<Int64>) {
        allowlist = ids
    }

    /// Replaces the configured repo allowlist at runtime (S16 — hot-reload from Settings), mirroring
    /// `updateAllowlist`. If the active repo is no longer configured it is dropped immediately, so a
    /// removed repo can't keep being operated on (§4a). Arm state is preserved.
    mutating func updateRepos(_ repos: [RepoConfig]) {
        repoConfigs = repos
        if let active = activeRepo, !repos.contains(where: { $0.name == active.name }) {
            activeRepo = nil
        }
    }

    /// Drops the session to disarmed immediately (S13b — the popover's "Disarm now" button). Same
    /// effect as a `/disarm` message, without routing through `authorize`; identity is not involved.
    /// Clears the active repo too — it lives with the session (§4a / S16).
    mutating func disarm() {
        armedUntil = nil
        activeRepo = nil
    }

    /// True while the armed window is still open.
    var isArmed: Bool {
        guard let armedUntil else { return false }
        return clock.now < armedUntil
    }

    /// The active repo, but only while armed — so a session that has idled out (lazy expiry) never
    /// reports a stale repo. Readers already gate on `isArmed` first, so this is belt-and-suspenders.
    var currentRepo: RepoConfig? { isArmed ? activeRepo : nil }

    /// Seconds left in the armed window, clamped to 0 (never negative); 0 when disarmed.
    var remainingArmedTime: TimeInterval {
        guard let armedUntil else { return 0 }
        return max(0, armedUntil.timeIntervalSince(clock.now))
    }

    /// Routes one operator message to a `Decision`, updating arm state as a side effect.
    mutating func authorize(fromId: Int64, text: String) -> Decision {
        // I2 / FR-2: identity gate first — check from.id (never chat id). Non-members dropped.
        guard allowlist.contains(fromId) else { return .rejectedUnknownUser }

        guard let token = text.split(whereSeparator: \.isWhitespace).first?.lowercased() else {
            return .unknownCommand   // empty / whitespace-only message from an allowlisted user
        }

        switch token {
        case "/arm":
            return .control(handleArm(text))
        case "/disarm":
            armedUntil = nil
            activeRepo = nil                              // the active repo lives with the session
            return .control(.disarmAccepted)
        case "/status":
            return .control(.status(isArmed: isArmed))   // read-only: never touches arm state
        case "/cd":
            return handleCd(text)
        case "/pwd":
            guard isArmed else { return .disarmed }       // repo context lives with the armed session
            return .control(.workingDirectory(currentRepo))
        case "/repos":
            guard isArmed else { return .disarmed }
            return .control(.repoList(repoConfigs))
        case "/claude":
            return resolveClaude(text)
        default:
            if let action = registry.match(text) {
                guard isArmed else { return .disarmed }    // I2: actions run only while armed
                extendArmedWindow()                        // authorized action resets idle timer
                return .runAction(action)
            }
            if let spec = parameterizedCommands.first(where: { $0.command.lowercased() == token }) {
                return resolveParameterized(spec, text: text)
            }
            if let sim = simulatorCommand, sim.command.lowercased() == token {
                return resolveSimulator(text: text)
            }
            return .unknownCommand
        }
    }

    // MARK: - Private

    /// Selects the session's active repo (§4a / S16). Gated on arm state first (I2) so a disarmed
    /// operator is told to arm rather than shown which repo names exist. The name is matched exactly
    /// against the configured allowlist — no path comes from chat, so traversal is impossible.
    private mutating func handleCd(_ text: String) -> Decision {
        guard isArmed else { return .disarmed }
        guard let name = operatorArguments(in: text).first else {
            return .invalidParameters("usage: /cd <repo>")
        }
        guard let repo = repoConfigs.first(where: { $0.name == name }) else {
            return .invalidParameters("unknown repo")
        }
        activeRepo = repo
        extendArmedWindow()                              // an intentional session action resets idle
        return .control(.activeRepoSet(repo))
    }

    /// Resolves a matched parameterized dev-workflow command to a `.runAction` or `.invalidParameters`.
    /// Arm gate first (I2), then — for a repo-scoped command — the active-repo precondition, then the
    /// per-parameter validation. The resolved action runs in the active repo's root (§4a).
    private mutating func resolveParameterized(_ spec: ParameterizedCommand, text: String) -> Decision {
        // I2: gate on arm state BEFORE validating, so a disarmed operator is told to arm rather
        // than shown a validation result.
        guard isArmed else { return .disarmed }

        var workingDirectory: String?
        if spec.requiresActiveRepo {
            guard let repo = currentRepo else { return .invalidParameters("select a repo first") }
            workingDirectory = repo.root
        }

        // §4a / S18: pass the active repo so a config-derived command (`/build`) can draw its
        // scheme/destination from `RepoConfig` — never operator text. Git commands ignore it.
        let argTokens = operatorArguments(in: text)
        switch ParameterizedActionResolver.resolve(spec, argTokens: argTokens,
                                                   repoTable: repoTable, activeRepo: currentRepo) {
        case let .ok(action):
            extendArmedWindow()
            // §4a: a repo-scoped command runs in the active repo's root (drawn only from config).
            return .runAction(workingDirectory.map(action.withWorkingDirectory) ?? action)
        case let .invalid(reason):
            return .invalidParameters(reason)            // §4a: nothing spawns on bad input
        }
    }

    /// Resolves the matched `/sim` command (§4a / S19) to a `.runActionSequence` or `.invalidParameters`.
    /// Same gate order as a repo-scoped parameterized command: arm state first (I2), then the
    /// active-repo precondition, then the no-operator-argument check, then the config-derived build.
    /// The step sequence is drawn entirely from the active repo's config — never operator text (I1).
    private mutating func resolveSimulator(text: String) -> Decision {
        guard isArmed else { return .disarmed }                       // I2 before anything else
        guard let repo = currentRepo else { return .invalidParameters("select a repo first") }
        guard operatorArguments(in: text).isEmpty else {
            return .invalidParameters("unexpected extra input")       // /sim takes no operator arg
        }
        switch SimulatorCommand.steps(for: repo) {
        case let .ok(steps):
            extendArmedWindow()
            return .runActionSequence(steps)
        case let .invalid(reason):
            return .invalidParameters(reason)            // §4a: a repo missing config spawns nothing
        }
    }

    /// Resolves the `/claude` agent action (§4b / S21). Gate order mirrors the other repo-scoped
    /// commands: arm state first (I2 — a disarmed operator is told to arm, not shown capability/repo
    /// state), then the capability toggle (I5 — OFF by default), then the active-repo precondition
    /// (the cwd that bounds Claude Code's file reach), then a non-empty prompt. The prompt is NOT
    /// validated — it is the one free-text parameter, contained by the profile + cwd, and is carried
    /// verbatim as a single inert token (I5): `operatorArguments` returns everything after `/claude`
    /// as ONE value, so shell metacharacters/leading dashes are never split off or read as flags.
    /// Nothing is built on refusal.
    private mutating func resolveClaude(_ text: String) -> Decision {
        guard isArmed else { return .disarmed }                                   // I2 before anything
        guard claudeEnabled else { return .invalidParameters("enable Claude in Settings") }
        guard let repo = currentRepo else { return .invalidParameters("select a repo first") }
        guard let prompt = operatorArguments(in: text).first else {
            return .invalidParameters("usage: /claude <prompt>")
        }
        extendArmedWindow()                                                       // an agent turn resets idle
        return .runClaude(prompt: prompt, repoRoot: repo.root, profile: claudeProfile)
    }

    /// The operator-supplied argument for a parameterized command: everything after the command
    /// token, as a single trimmed token (empty if none), preserving inner spacing so a multi-word
    /// commit message survives intact. All §4a commands take at most one such value.
    private func operatorArguments(in text: String) -> [String] {
        var i = text.startIndex
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }   // leading ws
        while i < text.endIndex, !text[i].isWhitespace { i = text.index(after: i) }  // command token
        while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }   // separating ws
        let rest = String(text[i...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return rest.isEmpty ? [] : [rest]
    }

    private mutating func handleArm(_ text: String) -> ControlResult {
        let wasArmed = isArmed
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else { return .armRejected }         // "/arm" with no code
        guard TOTP.validate(String(parts[1]), secret: totpSecret, at: clock.now) else {
            return .armRejected
        }
        if !wasArmed { activeRepo = nil }   // arming a fresh session starts with no active repo (§4a)
        extendArmedWindow()
        return .armAccepted
    }

    private mutating func extendArmedWindow() {
        armedUntil = clock.now.addingTimeInterval(idleTimeout)
    }
}
