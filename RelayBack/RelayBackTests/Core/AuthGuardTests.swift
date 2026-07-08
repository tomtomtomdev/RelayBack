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
                  registry: .seed,
                  clock: clock,
                  idleTimeout: idleTimeout)
    }

    /// A currently-valid code for `date`, produced by the same TOTP oracle the guard validates against.
    private func goodCode(at date: Date) -> String { TOTP.code(secret: secret, at: date) }

    private var uptime: Action { ActionRegistry.seed.match("/uptime")! }

    // MARK: - Identity gate (I2 / FR-2)

    @Test func unknownUserRejectedForEverything() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        // Even a valid control command or a valid TOTP code from a stranger is dropped,
        // and must never arm the session.
        #expect(guardState.authorize(fromId: stranger, text: "/uptime") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/arm \(goodCode(at: clock.now))") == .rejectedUnknownUser)
        #expect(guardState.authorize(fromId: stranger, text: "/status") == .rejectedUnknownUser)
        #expect(guardState.isArmed == false)
    }

    // MARK: - Disarmed blocks actions (I2)

    @Test func disarmedBlocksActions() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    // MARK: - Arming

    @Test func armWithBadCodeStaysDisarmed() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        let bad = goodCode(at: clock.now) == "000000" ? "111111" : "000000"
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(bad)") == .control(.armRejected))
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    @Test func armWithNoCodeRejected() {
        var guardState = makeGuard(TestClock(start))
        #expect(guardState.authorize(fromId: allowed, text: "/arm") == .control(.armRejected))
        #expect(guardState.isArmed == false)
    }

    @Test func armWithGoodCodeArmsAndActionRuns() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        #expect(guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))") == .control(.armAccepted))
        #expect(guardState.isArmed == true)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
    }

    // MARK: - Idle expiry & timer reset (FR-3)

    @Test func armExpiresAfterIdleWindow() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: idleTimeout + 1)
        #expect(guardState.isArmed == false)
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
    }

    @Test func actionResetsIdleTimer() {
        let clock = TestClock(start)
        var guardState = makeGuard(clock)
        _ = guardState.authorize(fromId: allowed, text: "/arm \(goodCode(at: clock.now))")
        clock.advance(by: 200)   // 200s < 300s window: still armed
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
        clock.advance(by: 200)   // 400s since arm, but only 200s since the action reset the timer
        // Without the reset this would have expired at 300s; with it, the session is still armed.
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
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
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .disarmed)
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
        #expect(guardState.authorize(fromId: allowed, text: "/uptime") == .runAction(uptime))
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
}
