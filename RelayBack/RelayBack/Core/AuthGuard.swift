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
    /// Authorized sender, armed session, matched `/release` (§4c / S29). Carries the full build+upload
    /// plan, built entirely from the active repo's config + the configured endpoint URL (never operator
    /// text, I1). The coordinator runs the archive→export build steps in order (stop on first failure),
    /// then performs the PGYER upload. The plan is secret-free — the API key is read from the Keychain
    /// only at spawn time (I3), never here.
    case runRelease(ReleasePlan)
    /// Authorized sender, armed session, matched `/pgyer` (§4c / S29) — upload the configured artifact
    /// without a rebuild. Carries the secret-free upload metadata; the coordinator reads the key at
    /// spawn time and folds it into a 0600 `curl --config` file (I3), never argv/audit/reply.
    case runPgyerUpload(PgyerUpload)
    /// Authorized sender, armed session, matched a parameterized command, but a parameter failed
    /// validation (§4a). Carries a short, secret-free reason; nothing is spawned.
    case invalidParameters(String)
    /// Authorized sender, but the text matches no action and no control command.
    case unknownCommand
}

/// The result of a control command.
enum ControlResult: Equatable {
    case armAccepted        // valid TOTP → session now armed
    case armRejected        // invalid TOTP → still disarmed
    case armPrompt          // /arm with no code → ask the operator to type it (S20)
    case disarmAccepted     // session dropped to disarmed
    case status(isArmed: Bool)
    // S16 — repo navigation (never executes a process; all report/mutate session state):
    case activeRepoSet(RepoConfig)      // /cd <repo> → active repo is now this one
    case workingDirectory(RepoConfig?)  // /pwd → the active repo (nil when none selected)
    case repoList([RepoConfig])         // /repos → the configured repo allowlist
    case cdPrompt([RepoConfig])         // /cd with no name → offer the configured repos to pick (S25)
    // S33 — configurable local scripts (§4d):
    case scriptMenu([Action])           // /run with several scripts → offer their labels to pick
}

struct AuthGuard {
    private var allowlist: Set<Int64>
    private let totpSecret: Data
    /// The fixed allowlist of runnable actions. `var` so the operator-picked local scripts (§4d /
    /// S33) can hot-reload it from Settings (`updateActions`) — each configured script is an ordinary
    /// registry `Action` (fixed absolute executable, empty argv; I1). `/run` selects among them.
    private var registry: ActionRegistry
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

    /// The `/release` and `/pgyer` command specs (§4c / S29), or nil when release/distribution is not
    /// enabled (the default, so every existing call site/test is unchanged). Production injects
    /// `ReleaseCommand.spec` / `.pgyerSpec`. When a token matches, the guard builds the plan from the
    /// active repo via `ReleaseCommand.plan`/`.upload` — never operator text (I1). Two separate specs
    /// (per the S28 decision) so each is injected/advertised independently.
    private let releaseCommand: ReleaseCommandSpec?
    private let pgyerCommand: ReleaseCommandSpec?

    /// The configured PGYER upload endpoint (§4c). Non-secret; passed to the plan builder as a curl
    /// argument. Only ever read when a `/release`/`/pgyer` token matches (i.e. the specs are injected),
    /// so the empty default is never used in production.
    private let pgyerUploadURL: String

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
    /// `var` so a Settings edit can hot-reload it (`updateClaudeConfig`, S22).
    private var claudeEnabled: Bool

    /// The Claude Code profile (executable, permission posture, timeout, model) carried in a
    /// `.runClaude` decision for the coordinator's runner. The guard never spawns — it only gates and
    /// packages the run. Fail-closed default (`restricted`, no executable) keeps I5 safe by default.
    /// `var` so a Settings edit can hot-reload it (`updateClaudeConfig`, S22).
    private var claudeProfile: ClaudeProfile

    /// True after `/arm` was sent with no code (S20): the operator was prompted to type the code,
    /// so their next bare (non-command) message is consumed as that code. Cleared once consumed,
    /// when a new command is issued instead, or on disarm — a bare number never arms out of context.
    private var awaitingArmCode = false

    /// True after `/cd` was sent with no name (S25): the operator was shown the repo picker, so
    /// their next bare (non-command) message — typically a tapped keyboard button — is consumed as
    /// the repo name. Cleared once consumed, when a new command is issued instead, or on disarm, so
    /// a bare word never silently switches the active repo out of context (mirrors `awaitingArmCode`).
    private var awaitingRepoName = false

    /// True after `/run` was sent with several scripts configured (S33): the operator was shown the
    /// script picker, so their next bare (non-command) message — a tapped label — is consumed as the
    /// script to run. Cleared once consumed, when a new command is issued instead, or on disarm, so a
    /// bare word never silently runs a script out of context (mirrors `awaitingRepoName`).
    private var awaitingScriptChoice = false

    init(allowlist: Set<Int64>,
         totpSecret: Data,
         registry: ActionRegistry,
         clock: Clock,
         idleTimeout: TimeInterval,
         parameterizedCommands: [ParameterizedCommand] = [],
         repoConfigs: [RepoConfig] = [],
         simulatorCommand: SimulatorCommandSpec? = nil,
         releaseCommand: ReleaseCommandSpec? = nil,
         pgyerCommand: ReleaseCommandSpec? = nil,
         pgyerUploadURL: String = "",
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
        self.releaseCommand = releaseCommand
        self.pgyerCommand = pgyerCommand
        self.pgyerUploadURL = pgyerUploadURL
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

    /// Replaces the runnable-action registry at runtime (S33 — hot-reload the operator-picked local
    /// scripts from the Settings pane), mirroring `updateAllowlist`/`updateRepos`. A script added or
    /// removed in Settings takes effect immediately: a removed one can no longer be run by `/run`
    /// (invariant I2). Arm state is preserved — the action set is orthogonal to the session. Any
    /// pending `/run` picker is dropped, so a stale label can't select a script that was just removed.
    mutating func updateActions(_ actions: [Action]) {
        registry = ActionRegistry(actions: actions)
        awaitingScriptChoice = false
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

    /// Replaces the `/claude` capability toggle + profile at runtime (S22 — hot-reload from the
    /// Settings Claude pane), mirroring `updateAllowlist`/`updateRepos`. Arm state and the active
    /// repo are preserved — capability is orthogonal to the session. Disabling takes effect at once:
    /// the next `/claude` fails the capability gate and nothing spawns (invariant I5). The guard only
    /// gates and packages the run, so swapping the profile can only change how a *future* run is
    /// bounded — it never touches anything already in flight.
    mutating func updateClaudeConfig(enabled: Bool, profile: ClaudeProfile) {
        claudeEnabled = enabled
        claudeProfile = profile
    }

    /// Drops the session to disarmed immediately (S13b — the popover's "Disarm now" button). Same
    /// effect as a `/disarm` message, without routing through `authorize`; identity is not involved.
    /// Clears the active repo too — it lives with the session (§4a / S16).
    mutating func disarm() {
        armedUntil = nil
        activeRepo = nil
        awaitingArmCode = false             // S20: drop any pending "type your code" prompt
        awaitingRepoName = false            // S25: drop any pending "pick a repo" prompt
        awaitingScriptChoice = false        // S33: drop any pending "pick a script" prompt
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

        // S20: after a code-less `/arm`, the operator's next non-command message is the TOTP code.
        if awaitingArmCode {
            awaitingArmCode = false
            if !token.hasPrefix("/") {
                return .control(handleArmCode(token))
            }
            // A new command instead of the code cancels the prompt — fall through and handle it.
        }

        // S25: after a code-less `/cd`, the operator's next non-command message (a tapped repo
        // button, or a typed name) is consumed as the repo to select. Match the whole trimmed
        // message so a name with spaces survives; a leading `/` is a new command that cancels it.
        if awaitingRepoName {
            awaitingRepoName = false
            if !token.hasPrefix("/") {
                guard isArmed else { return .disarmed }   // session may have idled out since the prompt
                return selectRepo(named: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // A new command instead of a repo name cancels the picker — fall through and handle it.
        }

        // S33: after a bare `/run` with several scripts, the next non-command message (a tapped
        // label, or a typed one) is consumed as the script to run. A leading `/` cancels the picker.
        if awaitingScriptChoice {
            awaitingScriptChoice = false
            if !token.hasPrefix("/") {
                guard isArmed else { return .disarmed }   // session may have idled out since the prompt
                return selectScript(labeled: text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // A new command instead of a label cancels the picker — fall through and handle it.
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
        case "/run":
            return resolveRun()
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
            if let rel = releaseCommand, rel.command.lowercased() == token {
                return resolveRelease(text: text)
            }
            if let pgyer = pgyerCommand, pgyer.command.lowercased() == token {
                return resolvePgyer(text: text)
            }
            return .unknownCommand
        }
    }

    // MARK: - Private

    /// Selects the session's active repo (§4a / S16). Gated on arm state first (I2) so a disarmed
    /// operator is told to arm rather than shown which repo names exist. With no name (S25), the
    /// configured repos are offered as a picker instead of an error, and the operator's next message
    /// is consumed as the choice (`awaitingRepoName`). The name is matched exactly against the
    /// configured allowlist — no path comes from chat, so traversal is impossible.
    private mutating func handleCd(_ text: String) -> Decision {
        guard isArmed else { return .disarmed }
        guard let name = operatorArguments(in: text).first else {
            guard !repoConfigs.isEmpty else { return .invalidParameters("no repos configured") }
            awaitingRepoName = true
            return .control(.cdPrompt(repoConfigs))
        }
        return selectRepo(named: name)
    }

    /// Sets the active repo by exact name match (shared by `/cd <name>` and the S25 picker reply).
    /// A name not on the configured allowlist is refused — nothing is selected.
    private mutating func selectRepo(named name: String) -> Decision {
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

    /// Resolves the matched `/release` command (§4c / S29) to a `.runRelease` or `.invalidParameters`.
    /// Same gate order as `/sim`: arm state first (I2), then the active-repo precondition, then the
    /// no-operator-argument check (I1 — trailing chat text is never an argument), then the config-
    /// derived plan. The plan is built entirely from the active repo + the configured endpoint URL,
    /// never operator text; a repo missing any required field makes the builder refuse (§4c, fails closed).
    private mutating func resolveRelease(text: String) -> Decision {
        guard isArmed else { return .disarmed }                       // I2 before anything else
        guard let repo = currentRepo else { return .invalidParameters("select a repo first") }
        guard operatorArguments(in: text).isEmpty else {
            return .invalidParameters("unexpected extra input")       // /release takes no operator arg
        }
        switch ReleaseCommand.plan(for: repo, uploadURL: pgyerUploadURL) {
        case let .ok(plan):
            extendArmedWindow()
            return .runRelease(plan)
        case let .invalid(reason):
            return .invalidParameters(reason)            // §4c: a repo missing config uploads nothing
        }
    }

    /// Resolves the matched `/pgyer` upload-only command (§4c / S29). Identical gating to `/release`,
    /// but builds only the upload step from the active repo's configured artifact (no rebuild).
    private mutating func resolvePgyer(text: String) -> Decision {
        guard isArmed else { return .disarmed }
        guard let repo = currentRepo else { return .invalidParameters("select a repo first") }
        guard operatorArguments(in: text).isEmpty else {
            return .invalidParameters("unexpected extra input")       // /pgyer takes no operator arg
        }
        switch ReleaseCommand.upload(for: repo, uploadURL: pgyerUploadURL) {
        case let .ok(upload):
            extendArmedWindow()
            return .runPgyerUpload(upload)
        case let .invalid(reason):
            return .invalidParameters(reason)
        }
    }

    /// Resolves the `/run` configurable-local-script trigger (§4d / S33). Arm gate first (I2 — a
    /// disarmed operator is told to arm, not shown which scripts exist), then: with no scripts
    /// configured it fails closed with a reason; with exactly one it runs directly; with several it
    /// offers the labels as a picker (the next bare message selects). The runnable actions come only
    /// from the operator-picked registry — no path, argument, or script content ever comes from chat
    /// (I1). Any operator text after `/run` is ignored: it never becomes an argument.
    private mutating func resolveRun() -> Decision {
        guard isArmed else { return .disarmed }
        let actions = registry.actions
        switch actions.count {
        case 0:
            return .invalidParameters("no scripts configured")
        case 1:
            extendArmedWindow()
            return .runAction(actions[0])
        default:
            awaitingScriptChoice = true
            return .control(.scriptMenu(actions))
        }
    }

    /// Runs a configured script by exact label match (shared by the S33 `/run` picker reply). The
    /// label selects a pre-configured registry `Action` — never a path or argument from chat (I1). A
    /// label not on the configured allowlist is refused; nothing spawns.
    private mutating func selectScript(labeled label: String) -> Decision {
        guard let action = registry.actions.first(where: { $0.description == label }) else {
            return .invalidParameters("unknown script")
        }
        extendArmedWindow()
        return .runAction(action)
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
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2 else {
            awaitingArmCode = true          // S20: "/arm" with no code → prompt for it, don't reject
            return .armPrompt
        }
        return handleArmCode(String(parts[1]))
    }

    /// Validates one TOTP code and, on success, arms the session — used both for `/arm <code>` and
    /// for the bare code that follows a code-less `/arm` prompt (S20).
    private mutating func handleArmCode(_ code: String) -> ControlResult {
        let wasArmed = isArmed
        guard TOTP.validate(code, secret: totpSecret, at: clock.now) else {
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
