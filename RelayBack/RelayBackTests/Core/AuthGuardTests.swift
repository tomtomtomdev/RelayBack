//
//  AuthGuardTests.swift
//  RelayBackTests
//
//  S3 — the arm/disarm state machine. These tests are the executable statement of invariant
//  I2 (no action runs unless the sender is allowlisted AND the session is armed) and FR-3
//  (TOTP arming, idle expiry, timer reset). The clock is injected so every time-dependent
//  case is deterministic.
//

import Foundation
import Testing
@testable import RelayBack

struct AuthGuardTests {

    // RFC 6238 seed "12345678901234567890" as raw key bytes — the secret under test.
    private let secret = Data("12345678901234567890".utf8)
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let allowed: Int64 = 111
    private let stranger: Int64 = 999
    private let idleTimeout: TimeInterval = 300

    // `RelayBack.Clock` qualified to disambiguate from the stdlib `Clock` protocol (both visible here).
    private func makeGuard(_ clock: RelayBack.Clock) -> AuthGuard {
        AuthGuard(allowlist: [allowed],
                  totpSecret: secret,
                  registry: ActionRegistry(actions: [disk]),
                  clock: clock,
                  idleTimeout: idleTimeout)
    }

    /// A currently-valid code for `date`, produced by the same TOTP oracle the guard validates against.
    private func goodCode(at date: Date) -> String { TOTP.code(secret: secret, at: date) }

    // The runnable-action fixture. The seed allowlist is now empty (legacy diagnostics removed),
    // so the guard under test is built with a registry containing just this action; `/disk`
    // selects it while armed (I1) and is blocked while disarmed / from a stranger (I2).
    private var disk: Action {
        Action(command: "/disk",
               description: "Disk usage, human-readable",
               executable: "/bin/df",
               arguments: ["-h"],
               timeout: 10)
    }

    // MARK: - Identity gate (I2 / FR-2)

    @Test func unknownUserRejectedForEverything() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        // Even a valid control command or a valid TOTP code from a stranger is dropped,
        // and must never arm the session.
        #expect(guardState.authorize(fromId: stranger, text: "/disk") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/arm \(goodCode(at: clock.now))") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/status") == .rejectedUnknownUser)
        #expect(guardState.isArmed == false)
    }

    // MARK: - Disarmed blocks actions (I2)

    @Test func disarmedBlocksActions() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .disarmed)
    }

    // MARK: - Agent action `/claude` gating (S21 — §4b / I5)

    /// A ready-to-run Claude profile for the enabled-path tests (executable is irrelevant to the
    /// guard — it never spawns; the coordinator's runner does).
    private var claudeProfile: ClaudeProfile {
        ClaudeProfile(executablePath: "/usr/local/bin/claude", permission: .restricted, timeout: 600)
    }

    private func makeGuard(_ clock: RelayBack.Clock,
                           claudeEnabled: Bool,
                           claudeProfile: ClaudeProfile,
                           repoConfigs: [RepoConfig]) -> AuthGuard {
        AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                  clock: clock, idleTimeout: idleTimeout,
                  repoConfigs: repoConfigs,
                  claudeEnabled: claudeEnabled, claudeProfile: claudeProfile)
    }

    @Test func claudeIsRefusedWhenDisabled() {
        // Default-OFF (I5): even armed + authorized with an active repo, `/claude` refuses until the
        // operator enables it in Settings. It is not silently unknown — the operator is told how.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: false, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        #expect(guardState.authorize(fromId: allowed, text: "/claude summarize the diff")
                == .invalidParameters("enable Claude in Settings"))
    }

    @Test func claudeRequiresAnArmedSession() {
        // I2 first: a disarmed operator is told to arm, never shown the capability/repo state.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        #expect(guardState.authorize(fromId: allowed, text: "/claude anything") == .disarmed)
    }

    @Test func claudeRequiresAnActiveRepo() {
        // Enabled + armed, but no `/cd` yet → the active-repo precondition (the cwd that bounds
        // Claude Code) fails, nothing is built.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/claude summarize the diff")
                == .invalidParameters("select a repo first"))
    }

    @Test func claudeRejectsAnEmptyPrompt() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        #expect(guardState.authorize(fromId: allowed, text: "/claude")
                == .invalidParameters("usage: /claude <prompt>"))
        #expect(guardState.authorize(fromId: allowed, text: "/claude    ")
                == .invalidParameters("usage: /claude <prompt>"))
    }

    @Test func claudeEnabledArmedWithRepoResolvesToRunClaude() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        // The decision carries the prompt, the active-repo root (the run cwd), and the profile.
        #expect(guardState.authorize(fromId: allowed, text: "/claude summarize the diff")
                == .runClaude(prompt: "summarize the diff",
                              repoRoot: relayback.root, profile: claudeProfile))
    }

    @Test func claudeCarriesAHostilePromptAsASingleInertToken() {
        // I5 at the guard: a prompt full of shell metacharacters is carried WHOLE as the single free-
        // text value — the guard never splits it into args or reads any part as a flag. Binding it to
        // `-p` (and keeping it inert at spawn) is proven by ClaudeInvocationTests / ClaudeRunnerTests.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        let hostile = "$HOME && echo pwned; rm -rf / --no-preserve-root"
        #expect(guardState.authorize(fromId: allowed, text: "/claude \(hostile)")
                == .runClaude(prompt: hostile, repoRoot: relayback.root, profile: claudeProfile))
    }

    @Test func updateClaudeConfigEnablesADisabledCapabilityWithoutReArming() {
        // S22 hot-reload (parity with updateAllowlist/updateRepos): flipping the toggle in Settings
        // reaches the live guard immediately. The operator stays armed with the same active repo —
        // capability is orthogonal to the session — so the very next `/claude` now resolves.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: false, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        #expect(guardState.authorize(fromId: allowed, text: "/claude summarize the diff")
                == .invalidParameters("enable Claude in Settings"))

        guardState.updateClaudeConfig(enabled: true, profile: claudeProfile)

        #expect(guardState.isArmed)                               // session preserved
        #expect(guardState.currentRepo == relayback)             // active repo preserved
        #expect(guardState.authorize(fromId: allowed, text: "/claude summarize the diff")
                == .runClaude(prompt: "summarize the diff",
                              repoRoot: relayback.root, profile: claudeProfile))
    }

    @Test func updateClaudeConfigDisablesAndSwapsTheProfileForFutureRuns() {
        // Disabling at runtime refuses the next `/claude` at once (I5). A swapped profile (e.g. the
        // operator changing the permission posture) is carried by subsequent decisions, never a run
        // already packaged.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, claudeEnabled: true, claudeProfile: claudeProfile,
                                   repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")

        let bypass = ClaudeProfile(executablePath: "/usr/local/bin/claude",
                                   permission: .fullBypass, timeout: 600)
        guardState.updateClaudeConfig(enabled: true, profile: bypass)
        #expect(guardState.authorize(fromId: allowed, text: "/claude go")
                == .runClaude(prompt: "go", repoRoot: relayback.root, profile: bypass))

        guardState.updateClaudeConfig(enabled: false, profile: bypass)
        #expect(guardState.authorize(fromId: allowed, text: "/claude go")
                == .invalidParameters("enable Claude in Settings"))
    }

    // MARK: - Arming

    @Test func armWithBadCodeStaysDisarmed() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        let bad = goodCode(at: clock.now) == "000000" ? "111111" : "000000"
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(bad)") == .control(.armRejected))
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .disarmed)
    }

    // S20 — `/arm` with no code (e.g. tapped from the Telegram command menu) does not reject
    // outright; it prompts the operator to type the code and stays disarmed until one arrives.
    @Test func armWithNoCodePromptsForCode() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armPrompt))
        #expect(guardState.isArmed == false)
    }

    // After the prompt, the operator's next (bare, non-command) message is consumed as the code.
    @Test func codeAfterPromptArmsTheSession() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armPrompt))
        #expect(guardState.authorize(fromId: allowed, text: goodCode(at: clock.now)) == .control(.armAccepted))
        #expect(guardState.isArmed == true)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .runAction(disk))
    }

    // A bad code supplied after the prompt is rejected and leaves the session disarmed.
    @Test func badCodeAfterPromptStaysDisarmed() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        let bad = goodCode(at: clock.now) == "000000" ? "111111" : "000000"
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armPrompt))
        #expect(guardState.authorize(fromId: allowed, text: bad) == .control(.armRejected))
        #expect(guardState.isArmed == false)
    }

    // A bare code is ONLY treated as an arm code right after a prompt — otherwise it is unknown,
    // so an idle numeric message can never silently arm the session (I2).
    @Test func bareCodeWithoutPromptIsNotAnArmCode() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: goodCode(at: clock.now)) == .unknownCommand)
        #expect(guardState.isArmed == false)
    }

    // Typing a new command instead of the code cancels the pending prompt: the command is handled
    // normally, and the awaited-code state is cleared (a later bare code no longer arms).
    @Test func commandAfterPromptCancelsAwaitingCode() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armPrompt))
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: false)))
        // The prompt was cancelled by the command — a subsequent bare code is no longer consumed.
        #expect(guardState.authorize(fromId: allowed, text: goodCode(at: clock.now)) == .unknownCommand)
        #expect(guardState.isArmed == false)
    }

    @Test func armWithGoodCodeArmsAndActionRuns() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))") == .control(.armAccepted))
        #expect(guardState.isArmed == true)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .runAction(disk))
    }

    // MARK: - Idle expiry & timer reset (FR-3)

    @Test func armExpiresAfterIdleWindow() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: idleTimeout + 1)
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .disarmed)
    }

    @Test func actionResetsIdleTimer() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: 200)   // 200s < 300s window: still armed
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .runAction(disk))
        clock.advance(by: 200)   // 400s since arm, but only 200s since the action reset the timer
        // Without the reset this would have expired at 300s; with it, the session is still armed.
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .runAction(disk))
    }

    @Test func remainingArmedTimeReflectsClockAndClamps() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.remainingArmedTime == 0)                 // disarmed
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.remainingArmedTime == idleTimeout)       // just armed
        clock.advance(by: 120)
        #expect(guardState.remainingArmedTime == idleTimeout - 120)
        clock.advance(by: idleTimeout)                              // well past expiry
        #expect(guardState.remainingArmedTime == 0)                 // clamped, never negative
    }

    // MARK: - Disarm

    @Test func disarmEndsSession() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/disarm") == .control(.disarmAccepted))
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .disarmed)
    }

    // MARK: - Status never executes

    @Test func statusReportsAndNeverExecutes() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: false)))
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: true)))
        #expect(guardState.isArmed == true)   // status is a read; it must not change arm state
    }

    // MARK: - Unknown commands

    @Test func unknownCommandNeverRuns() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/frobnicate") == .unknownCommand)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/frobnicate") == .unknownCommand)
    }

    // MARK: - Runtime allowlist changes (S12 — hot-reload, arm state preserved)

    @Test func updateAllowlistAddsAndRemovesWhoIsRecognized() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)   // allowlist = [allowed]
        let newcomer: Int64 = 222

        // Before: the newcomer is an unknown user; `allowed` is recognized (its command is unknown).
        #expect(guardState.authorize(fromId: newcomer, text: "/status") == .rejectedUnknownUser)

        guardState.updateAllowlist([allowed, newcomer])
        // Now the newcomer is recognized — a control command is handled, not dropped.
        #expect(guardState.authorize(fromId: newcomer, text: "/status") == .control(.status(isArmed: false)))

        // Removing an id revokes it immediately (I2 — immediate revocation).
        guardState.updateAllowlist([newcomer])
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .rejectedUnknownUser)
    }

    @Test func updateAllowlistPreservesArmState() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.isArmed)

        guardState.updateAllowlist([allowed, 222])   // editing identity must not drop a live session
        #expect(guardState.isArmed)
        #expect(guardState.authorize(fromId: allowed, text: "/disk") == .runAction(disk))
    }

    // MARK: - Casing

    @Test func controlTokensAreCaseInsensitive() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/ARM \(goodCode(at: clock.now))") == .control(.armAccepted))
        #expect(guardState.authorize(fromId: allowed, text: "/Status") == .control(.status(isArmed: true)))
        #expect(guardState.authorize(fromId: allowed, text: "/DisArm") == .control(.disarmAccepted))
    }

    // MARK: - Parameterized-action routing (S15 — mechanism present, inert in production)

    // A representative spec standing in for the S17+ git commands; only tests inject it.
    private var checkoutSpec: ParameterizedCommand {
        ParameterizedCommand(command: "/checkout", description: "Switch branch",
                             executable: "/usr/bin/git", fixedArgs: ["checkout", "--"],
                             parameters: [.branch], timeout: 20)
    }

    private func makeGuard(_ clock: RelayBack.Clock,
                           commands: [ParameterizedCommand],
                           repoConfigs: [RepoConfig] = [],
                           simulatorCommand: SimulatorCommandSpec? = nil) -> AuthGuard {
        AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                  clock: clock, idleTimeout: idleTimeout,
                  parameterizedCommands: commands, repoConfigs: repoConfigs,
                  simulatorCommand: simulatorCommand)
    }

    @Test func parameterizedCommandIsNotMatchableWithNoConfiguredSpecs() {
        // S15 done-when: the mechanism exists but no new command resolves in production (empty
        // spec set), so a parameterized-looking command is just unknown — nothing new is matchable.
        let clock = TestClock(start)
        var guardState = makeGuard(clock)   // default init: no parameterized commands
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        #expect(guardState.authorize(fromId: allowed, text: "/checkout main") == .unknownCommand)
    }

    @Test func armedValidParameterResolvesToRunAction() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [checkoutSpec])
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        let expected = Action(command: "/checkout", description: "Switch branch",
                              executable: "/usr/bin/git", arguments: ["checkout", "--", "main"],
                              timeout: 20)
        #expect(guardState.authorize(fromId: allowed, text: "/checkout main") == .runAction(expected))
    }

    @Test func armedInvalidParameterReturnsInvalidParametersAndDoesNotRun() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [checkoutSpec])
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        // A branch beginning with '-' is rejected before anything is built (I1 / §4a).
        #expect(guardState.authorize(fromId: allowed, text: "/checkout -x")
                == .invalidParameters("invalid branch name"))
    }

    @Test func parameterizedCommandRequiresArmedSessionBeforeValidating() {
        // I2: identity + arm gate come first — a disarmed operator is told to arm, not shown a
        // validation result (which could leak whether the command/params were otherwise valid).
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [checkoutSpec])
        #expect(guardState.authorize(fromId: allowed, text: "/checkout main") == .disarmed)
        #expect(guardState.authorize(fromId: allowed, text: "/checkout -x") == .disarmed)
    }

    // MARK: - Repo navigation & active-repo session state (S16)

    private var relayback: RepoConfig {
        RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                   scheme: "RelayBack", destination: "platform=macOS")
    }
    private var notes: RepoConfig { RepoConfig(name: "notes", root: "/Users/op/dev/Notes") }

    /// A repo-scoped git command standing in for the S17 commands — runs in the active repo, no arg.
    private var gitStatusSpec: ParameterizedCommand {
        ParameterizedCommand(command: "/gitstatus", description: "Working tree status",
                             executable: "/usr/bin/git", fixedArgs: ["status"],
                             parameters: [], timeout: 20, requiresActiveRepo: true)
    }

    private func armed(_ guardState: inout AuthGuard, _ clock: TestClock) {
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
    }

    @Test func cdUnknownRepoIsInvalidParameters() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/cd nope") == .invalidParameters("unknown repo"))
        #expect(guardState.currentRepo == nil)   // nothing was selected
    }

    @Test func cdValidRepoSetsTheActiveContext() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/cd relayback") == .control(.activeRepoSet(relayback)))
        #expect(guardState.currentRepo == relayback)
    }

    @Test func cdRequiresAnArmedSession() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback])
        #expect(guardState.authorize(fromId: allowed, text: "/cd relayback") == .disarmed)
    }

    // MARK: - /cd repo picker (S25) — bare `/cd` offers the configured repos to pick from

    // Armed `/cd` with no name offers the configured repos instead of an error.
    @Test func bareCdOffersTheConfiguredReposToPick() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/cd") == .control(.cdPrompt([relayback, notes])))
        #expect(guardState.currentRepo == nil)   // nothing selected yet — awaiting the pick
    }

    // After the picker, the operator's next (bare, non-command) message — a tapped button — selects.
    @Test func repoNameAfterCdPromptSelectsIt() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/cd") == .control(.cdPrompt([relayback, notes])))
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .control(.activeRepoSet(notes)))
        #expect(guardState.currentRepo == notes)
    }

    // A name that isn't configured, supplied after the picker, is refused — nothing is selected.
    @Test func unknownRepoNameAfterCdPromptIsRejected() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd")
        #expect(guardState.authorize(fromId: allowed, text: "nope") == .invalidParameters("unknown repo"))
        #expect(guardState.currentRepo == nil)
    }

    // Issuing a new command instead of picking cancels the picker: the command is handled normally,
    // and a later bare word is no longer consumed as a repo name (mirrors the /arm prompt, S20).
    @Test func commandAfterCdPromptCancelsThePicker() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd")
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: true)))
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .unknownCommand)   // picker cancelled
        #expect(guardState.currentRepo == nil)
    }

    // A bare repo name is ONLY consumed right after the picker — otherwise it is unknown, so an idle
    // word can never silently switch the active repo out of context (the I2-style guard from S20).
    @Test func bareRepoNameWithoutPromptIsUnknown() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .unknownCommand)
        #expect(guardState.currentRepo == nil)
    }

    // Bare `/cd` while disarmed still tells the operator to arm — it does NOT leak the repo names,
    // and no pick is awaited (a following bare word is unknown, not a silent selection).
    @Test func bareCdWhileDisarmedDoesNotOfferThePicker() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        #expect(guardState.authorize(fromId: allowed, text: "/cd") == .disarmed)
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .unknownCommand)
    }

    // With no repos configured, bare `/cd` says so rather than showing an empty picker, and awaits
    // nothing (a following word is unknown, not consumed).
    @Test func bareCdWithNoReposConfiguredSaysSo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/cd") == .invalidParameters("no repos configured"))
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .unknownCommand)
    }

    // Disarming (the popover button) drops a pending picker, so a bare word after re-arming is not
    // consumed as a repo name — the awaited-pick state does not survive the session.
    @Test func disarmMethodClearsAPendingCdPicker() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd")   // picker shown, awaiting a pick
        guardState.disarm()
        armed(&guardState, clock)                                // re-arm a fresh session
        #expect(guardState.authorize(fromId: allowed, text: "notes") == .unknownCommand)
        #expect(guardState.currentRepo == nil)
    }

    @Test func pwdReportsActiveRepoAndReposListsConfigured() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/pwd") == .control(.workingDirectory(nil)))
        #expect(guardState.authorize(fromId: allowed, text: "/repos") == .control(.repoList([relayback, notes])))
        _ = guardState.authorize(fromId: allowed, text: "/cd notes")
        #expect(guardState.authorize(fromId: allowed, text: "/pwd") == .control(.workingDirectory(notes)))
    }

    @Test func repoScopedCommandWithNoActiveRepoIsRejected() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [gitStatusSpec], repoConfigs: [relayback])
        armed(&guardState, clock)
        // Armed, valid command, but no repo selected yet → the §4a precondition fails, nothing runs.
        #expect(guardState.authorize(fromId: allowed, text: "/gitstatus") == .invalidParameters("select a repo first"))
    }

    @Test func repoScopedCommandRunsInTheActiveRepoRoot() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [gitStatusSpec], repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        let expected = Action(command: "/gitstatus", description: "Working tree status",
                              executable: "/usr/bin/git", arguments: ["status"],
                              timeout: 20, workingDirectory: "/Users/op/dev/RelayBack")
        #expect(guardState.authorize(fromId: allowed, text: "/gitstatus") == .runAction(expected))
    }

    @Test func disarmClearsTheActiveRepo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [gitStatusSpec], repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        #expect(guardState.currentRepo == relayback)

        _ = guardState.authorize(fromId: allowed, text: "/disarm")
        armed(&guardState, clock)                 // re-arm a fresh session
        #expect(guardState.currentRepo == nil)    // the repo did not survive the disarm (§4a / S16)
        #expect(guardState.authorize(fromId: allowed, text: "/gitstatus") == .invalidParameters("select a repo first"))
    }

    @Test func disarmMethodClearsTheActiveRepo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        guardState.disarm()                       // the popover's "Disarm now"
        armed(&guardState, clock)
        #expect(guardState.currentRepo == nil)
    }

    // MARK: - /build reads the active repo's build config (S18)

    @Test func buildRunsWithConfigArgvInTheActiveRepoRoot() {
        // The guard must thread the active repo's RepoConfig (not just its root) into the resolver,
        // so the scheme/destination argv is drawn from config — never operator text (§4a / S18).
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: BuildCommands.all, repoConfigs: [relayback])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")
        let expected = Action(
            command: "/build", description: BuildCommands.all[0].description,
            executable: "/usr/bin/xcodebuild",
            arguments: ["-scheme", "RelayBack", "-destination", "platform=macOS", "build"],
            timeout: BuildCommands.all[0].timeout, workingDirectory: "/Users/op/dev/RelayBack")
        #expect(guardState.authorize(fromId: allowed, text: "/build") == .runAction(expected))
    }

    @Test func buildRejectsWhenActiveRepoHasNoScheme() {
        // `notes` is a plain repo with no scheme/destination → /build refuses, nothing spawns.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: BuildCommands.all, repoConfigs: [notes])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd notes")
        #expect(guardState.authorize(fromId: allowed, text: "/build")
                == .invalidParameters("no scheme configured for this repo"))
    }

    @Test func updateReposHotReloadsAndDropsARemovedActiveRepo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback, notes])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd notes")
        #expect(guardState.currentRepo == notes)

        guardState.updateRepos([relayback])       // `notes` removed in Settings
        #expect(guardState.currentRepo == nil)    // the removed active repo is dropped immediately
        // A newly-added repo becomes selectable without a restart.
        #expect(guardState.authorize(fromId: allowed, text: "/cd relayback") == .control(.activeRepoSet(relayback)))
    }

    // MARK: - /sim multi-step simulator run (S19)

    /// A repo fully configured for the simulator (scheme + destination + device).
    private var simRepo: RepoConfig {
        RepoConfig(name: "app", root: "/Users/op/dev/App",
                   scheme: "App", destination: "platform=iOS Simulator,name=iPhone 15",
                   simulatorDevice: "iPhone 15")
    }

    @Test func simNotMatchableWhenNotConfigured() {
        // Mirrors the parameterized-command inertness test: with no sim command injected, /sim is
        // just an unknown command — nothing new is matchable.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [simRepo])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd app")
        #expect(guardState.authorize(fromId: allowed, text: "/sim") == .unknownCommand)
    }

    @Test func simRunsStepSequenceInTheActiveRepo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [simRepo],
                                   simulatorCommand: SimulatorCommand.spec)
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd app")
        guard case let .ok(expected) = SimulatorCommand.steps(for: simRepo) else {
            return #expect(Bool(false), "fixture repo should resolve")
        }
        #expect(guardState.authorize(fromId: allowed, text: "/sim") == .runActionSequence(expected))
    }

    @Test func simRequiresAnActiveRepo() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [simRepo],
                                   simulatorCommand: SimulatorCommand.spec)
        armed(&guardState, clock)
        // Armed, but no /cd yet → the §4a precondition fails, nothing runs.
        #expect(guardState.authorize(fromId: allowed, text: "/sim")
                == .invalidParameters("select a repo first"))
    }

    @Test func simRejectsRepoWithNoSimulatorDevice() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [relayback],
                                   simulatorCommand: SimulatorCommand.spec)
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd relayback")   // relayback has no device
        #expect(guardState.authorize(fromId: allowed, text: "/sim")
                == .invalidParameters("no simulator device configured for this repo"))
    }

    @Test func simAcceptsNoOperatorArguments() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [simRepo],
                                   simulatorCommand: SimulatorCommand.spec)
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/cd app")
        // A trailing token must not smuggle anything through — /sim takes no operator argument.
        #expect(guardState.authorize(fromId: allowed, text: "/sim iPhone")
                == .invalidParameters("unexpected extra input"))
    }

    @Test func simRequiresArmedSession() {
        // I2: identity + arm gate come first — a disarmed operator is told to arm, not shown a result.
        let clock = TestClock(start)
        var guardState = makeGuard(clock, commands: [], repoConfigs: [simRepo],
                                   simulatorCommand: SimulatorCommand.spec)
        #expect(guardState.authorize(fromId: allowed, text: "/sim") == .disarmed)
    }

    // MARK: - Configurable local scripts (/run) — S33

    // Two operator-picked scripts. The registry the guard runs against is seeded from their
    // config→action map (mirrors what `AppRuntime` does from `ConfigStore.scripts()`).
    private var deployScript: ScriptConfig {
        ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh")
    }
    private var backupScript: ScriptConfig {
        ScriptConfig(label: "Backup", path: "/Users/op/bin/backup.sh")
    }

    private func makeScriptGuard(_ clock: RelayBack.Clock, scripts: [ScriptConfig]) -> AuthGuard {
        AuthGuard(allowlist: [allowed], totpSecret: secret,
                  registry: ActionRegistry(actions: scripts.compactMap { $0.toAction() }),
                  clock: clock, idleTimeout: idleTimeout)
    }

    // I2: identity + arm gate first — a disarmed operator is told to arm, not shown the script menu.
    @Test func runRequiresAnArmedSession() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        #expect(guardState.authorize(fromId: allowed, text: "/run") == .disarmed)
    }

    // With no scripts configured, `/run` says so rather than spawning anything (fails closed).
    @Test func runWithNoScriptsConfiguredSaysSo() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/run")
                == .invalidParameters("no scripts configured"))
    }

    // A single configured script runs directly — no picker needed.
    @Test func runWithOneScriptRunsItDirectly() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/run") == .runAction(deployScript.toAction()!))
    }

    // Several scripts → the picker (labels), consumed by the next bare message (mirrors /cd, S25).
    @Test func runWithSeveralScriptsOffersThePicker() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/run")
                == .control(.scriptMenu([deployScript.toAction()!, backupScript.toAction()!])))
    }

    // After the picker, the operator's next (bare) message — a tapped label — selects & runs it.
    @Test func scriptLabelAfterRunPromptSelectsIt() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/run")
        #expect(guardState.authorize(fromId: allowed, text: "Backup") == .runAction(backupScript.toAction()!))
    }

    // A label that isn't configured, supplied after the picker, is refused — nothing spawns.
    @Test func unknownScriptLabelAfterRunPromptIsRejected() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/run")
        #expect(guardState.authorize(fromId: allowed, text: "nope") == .invalidParameters("unknown script"))
    }

    // A new command instead of picking cancels the picker (mirrors the /cd + /arm prompts).
    @Test func commandAfterRunPromptCancelsThePicker() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        armed(&guardState, clock)
        _ = guardState.authorize(fromId: allowed, text: "/run")
        #expect(guardState.authorize(fromId: allowed, text: "/status") == .control(.status(isArmed: true)))
        #expect(guardState.authorize(fromId: allowed, text: "Backup") == .unknownCommand)   // picker cancelled
    }

    // A bare label is ONLY consumed right after the picker — otherwise an idle word never silently
    // runs a script (the I2-style guard from S20/S25).
    @Test func bareScriptLabelWithoutPromptIsUnknown() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript, backupScript])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "Backup") == .unknownCommand)
    }

    // Hot-reload: a script added in Settings runs once armed; a removed one can no longer run (I2).
    @Test func updateActionsHotReloadsRunnableScripts() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [])
        armed(&guardState, clock)
        #expect(guardState.authorize(fromId: allowed, text: "/run") == .invalidParameters("no scripts configured"))

        guardState.updateActions([deployScript.toAction()!])
        #expect(guardState.authorize(fromId: allowed, text: "/run") == .runAction(deployScript.toAction()!))

        guardState.updateActions([])                       // removed in Settings
        #expect(guardState.authorize(fromId: allowed, text: "/run") == .invalidParameters("no scripts configured"))
    }

    // I1: chat text after `/run` never becomes an argument or the executable — it is ignored; the
    // resolved action is exactly the configured one (empty argv, the picked script's own path).
    @Test func trailingChatTextAfterRunIsNeverAnArgument() {
        let clock = TestClock(start)
        var guardState = makeScriptGuard(clock, scripts: [deployScript])
        armed(&guardState, clock)
        let decision = guardState.authorize(fromId: allowed, text: "/run rm -rf / ; echo pwned")
        #expect(decision == .runAction(deployScript.toAction()!))
        if case let .runAction(action) = decision {
            #expect(action.arguments.isEmpty)                        // no operator text reached argv
            #expect(action.executable == "/Users/op/bin/deploy.sh")  // exactly the configured script
        }
    }
}
