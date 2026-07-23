//
//  AppCoordinatorTests.swift
//  RelayBackTests
//
//  S8 — the orchestration brain, tested end-to-end against fakes (no network, no real Process,
//  no Keychain). These scenarios are the executable proof of the run-path invariants:
//    • I2 — a process is spawned ONLY for an allowlisted sender with an armed session. Every
//      other decision (unknown user, disarmed, bad code, unknown command) leaves the runner
//      untouched (`runCount == 0`).
//    • I1 — the runner only ever receives a registry-defined `Action`; operator text merely
//      selects it (proven by the recorded action equalling the seeded `/disk`).
//    • I3 — the audit entry for a run carries only the command token + exit code, never output.
//  It also pins the FR-6 reply shaping: normal output → formatted text, oversized → a document.
//

import Foundation
import Testing
@testable import RelayBack

struct AppCoordinatorTests {

    // RFC 6238 seed as raw key bytes — the same oracle AuthGuard validates `/arm` against.
    private let secret = Data("12345678901234567890".utf8)
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private let allowed: Int64 = 111
    private let stranger: Int64 = 999
    private let chat: Int64 = 500
    private let idleTimeout: TimeInterval = 300

    /// Bundles the coordinator with the fakes and clock so a test can drive it and then inspect
    /// exactly what was run, sent, and audited.
    private struct Harness {
        let coordinator: AppCoordinator
        let transport: FakeTelegramTransport
        let runner: FakeCommandRunner
        let audit: InMemoryAuditSink
        let clock: TestClock
        /// Set only by the `/claude` harness (S21) — the agent runner, so a test can assert it was
        /// (or, for the I5 refusal cases, was NOT) invoked. nil for the fixed-action harnesses.
        var claudeRunner: FakeClaudeRunner? = nil
        /// Set only by the `/release`/`/pgyer` harness (S29) — the curl-config writer, so a test can
        /// prove the PGYER key went into the config FILE (the intended I3 channel) and nowhere else.
        var curlWriter: FakeCurlConfigWriter? = nil
    }

    private func makeHarness(result: CommandResult = CommandResult(exitCode: 0, stdout: "up 3 days", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner(result: result)
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed],
                                  totpSecret: secret,
                                  registry: ActionRegistry(actions: [disk]),
                                  clock: clock,
                                  idleTimeout: idleTimeout)
        let coordinator = AppCoordinator(authGuard: authGuard,
                                         runner: runner,
                                         transport: transport,
                                         audit: audit,
                                         clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner, audit: audit, clock: clock)
    }

    private func update(fromId: Int64?, text: String?, updateId: Int64 = 1) -> TelegramUpdate {
        let user = fromId.map { TelegramUser(id: $0) }
        let message = TelegramMessage(from: user, chat: TelegramChat(id: chat), text: text)
        return TelegramUpdate(updateId: updateId, message: message)
    }

    private func goodCode(at date: Date) -> String { TOTP.code(secret: secret, at: date) }

    // The runnable-action fixture. The seed allowlist is now empty (legacy diagnostics removed),
    // so the harness injects a registry containing just this action; `/disk` selects it (I1).
    private var disk: Action {
        Action(command: "/disk",
               description: "Disk usage, human-readable",
               executable: "/bin/df",
               arguments: ["-h"],
               timeout: 10)
    }

    // MARK: - Authorized + armed action runs and replies with formatted output

    @Test func armedAuthorizedActionRunsAndRepliesFormatted() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        // I1/I2: exactly one process, and it is the registry action selected by the token.
        #expect(h.runner.runActions == [disk])

        // FR-6: the formatted result is what OutputFormatter produces, sent as text to the chat.
        let expected = OutputFormatter.format(CommandResult(exitCode: 0, stdout: "up 3 days", stderr: ""))
        let outputMessages = h.transport.sentMessages.filter { $0.chatId == chat }.map { $0.text }
        #expect(outputMessages.contains { $0.contains("up 3 days") && $0.contains("exit 0") })
        #expect(expected.count == 1)   // small output → one text message

        // I3: the run is audited by command token + exit code only — never the output.
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/disk", exitCode: 0) })
        #expect(h.audit.entries.allSatisfy { !$0.line.contains("up 3 days") })
    }

    // MARK: - Unknown user: dropped, nothing run, no reply, rejection audited (I2 / FR-2)

    @Test func unknownUserDroppedNothingRunNoReply() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: stranger, text: "/disk"))

        #expect(h.runner.runCount == 0)                 // I2: no spawn for a stranger
        #expect(h.transport.sentMessages.isEmpty)       // FR-2: strangers get no reply at all
        #expect(h.transport.sentDocuments.isEmpty)
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "unknown user")])
    }

    // MARK: - Disarmed action: replied, runner NOT called (I2)

    @Test func disarmedActionRepliesAndDoesNotRun() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        #expect(h.runner.runCount == 0)                 // I2: armed session required to run
        #expect(h.transport.sentMessages.count == 1)
        #expect(h.transport.sentMessages.first?.text.lowercased().contains("disarm") == true)
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "disarmed")])
    }

    // MARK: - /arm flow: bad code does not arm; good code arms

    @Test func badArmCodeDoesNotArmAndIsAudited() async {
        let h = makeHarness()
        let bad = goodCode(at: h.clock.now) == "000000" ? "111111" : "000000"
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(bad)"))
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        #expect(h.runner.runCount == 0)                 // still disarmed after a bad code
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "bad code"), .rejected(reason: "disarmed")])
    }

    @Test func armFlowRepliesAndAuditsControl() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))

        #expect(h.transport.sentMessages.count == 1)
        #expect(h.transport.sentMessages.first?.text.lowercased().contains("armed") == true)
        #expect(h.audit.entries.map(\.event) == [.control("armed")])
        #expect(h.runner.runCount == 0)                 // arming never runs an action
    }

    // MARK: - /arm with no code prompts for it via force_reply, then arms on the reply (S20)

    @Test func armWithNoCodePromptsWithForceReplyAndDoesNotRun() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm"))

        #expect(h.runner.runCount == 0)                          // nothing spawned by a prompt
        #expect(h.transport.sentMessages.count == 1)
        let prompt = h.transport.sentMessages.first
        #expect(prompt?.markup == .forceReply)                   // opens the keyboard to type the code
        #expect(prompt?.text.contains("code") == true)
        #expect(h.coordinator.isArmed == false)                  // still disarmed until a code arrives
        #expect(h.audit.entries.map(\.event) == [.control("arm prompt")])
    }

    @Test func codeReplyAfterPromptArmsTheSession() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm"))
        await h.coordinator.handle(update(fromId: allowed, text: goodCode(at: h.clock.now)))

        #expect(h.coordinator.isArmed == true)
        #expect(h.transport.sentMessages.last?.text.lowercased().contains("armed") == true)
        #expect(h.audit.entries.map(\.event) == [.control("arm prompt"), .control("armed")])
    }

    // MARK: - Oversized output → a single document (FR-6)

    @Test func oversizedOutputSentAsDocument() async {
        let big = String(repeating: "x", count: OutputFormatter.documentThreshold + 1)
        let h = makeHarness(result: CommandResult(exitCode: 0, stdout: big, stderr: ""))
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        #expect(h.transport.sentDocuments.count == 1)
        #expect(h.transport.sentDocuments.first?.filename == "output.txt")
        #expect(h.transport.sentDocuments.first?.chatId == chat)
        // The only text message is the arm confirmation; the output went out as a document.
        #expect(h.transport.sentMessages.count == 1)
    }

    // MARK: - Control replies & audits

    @Test func statusIsReportedAndAuditedWithoutRunning() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/status"))

        #expect(h.runner.runCount == 0)
        #expect(h.transport.sentMessages.count == 1)
        #expect(h.audit.entries.map(\.event) == [.control("status armed=false")])
    }

    @Test func unknownCommandIsRepliedAndAudited() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/frobnicate"))

        #expect(h.runner.runCount == 0)
        #expect(h.transport.sentMessages.count == 1)
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "unknown command")])
    }

    // MARK: - Arm state exposed for the menu bar (S11)

    @Test func exposesLiveArmStateForTheMenuBar() async {
        let h = makeHarness()
        #expect(h.coordinator.isArmed == false)
        #expect(h.coordinator.remainingArmedTime == 0)

        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))

        #expect(h.coordinator.isArmed)
        #expect(h.coordinator.remainingArmedTime == idleTimeout)
    }

    // MARK: - Runtime allowlist wiring (S12): a newly-added id can arm and run

    @Test func updateAllowlistLetsANewlyAddedIdArmAndRun() async {
        let h = makeHarness()            // allowlist starts as [allowed]; `newcomer` is a stranger
        let newcomer: Int64 = 222

        // Before wiring: the newcomer is dropped and nothing runs (I2).
        await h.coordinator.handle(update(fromId: newcomer, text: "/disk"))
        #expect(h.runner.runCount == 0)

        h.coordinator.updateAllowlist([allowed, newcomer])
        await h.coordinator.handle(update(fromId: newcomer, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: newcomer, text: "/disk"))

        // The newly-authorized id armed and ran exactly the registry action (I1/I2).
        #expect(h.runner.runActions == [disk])
    }

    @Test func updateAllowlistRevokesARemovedId() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))

        h.coordinator.updateAllowlist([])   // remove everyone
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        #expect(h.runner.runCount == 0)     // I2: a removed id can no longer run, even mid-session
    }

    // MARK: - Disarm hook & last-result push for the popover (S13b)

    @Test func disarmDropsTheLiveSessionSoNothingRuns() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        #expect(h.coordinator.isArmed)

        h.coordinator.disarm()                          // the popover's "Disarm now" target
        #expect(h.coordinator.isArmed == false)

        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))
        #expect(h.runner.runCount == 0)                 // I2: disarmed by the UI → nothing runs
    }

    @Test func onActionCompletedReceivesCommandAndResult() async {
        let h = makeHarness()                           // default result: exit 0, "up 3 days"
        var received: (command: String, result: CommandResult)?
        h.coordinator.onActionCompleted = { received = ($0, $1) }

        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/disk"))

        #expect(received?.command == "/disk")
        #expect(received?.result == CommandResult(exitCode: 0, stdout: "up 3 days", stderr: ""))
    }

    // MARK: - Non-actionable updates are ignored

    @Test func updateWithoutMessageOrSenderOrTextIsIgnored() async {
        let h = makeHarness()
        await h.coordinator.handle(TelegramUpdate(updateId: 1, message: nil))              // no message
        await h.coordinator.handle(update(fromId: nil, text: "/disk"))                    // no sender (channel post)
        await h.coordinator.handle(update(fromId: allowed, text: nil))                      // no text

        #expect(h.runner.runCount == 0)
        #expect(h.transport.sentMessages.isEmpty)
        #expect(h.transport.sentDocuments.isEmpty)
        #expect(h.audit.entries.isEmpty)
    }

    // MARK: - Parameterized actions (S15): invalid params warn + audit, no run; valid resolves & runs

    // A representative spec wired into the guard for these tests only — S15 wires none in production.
    private let checkoutSpec = ParameterizedCommand(
        command: "/checkout", description: "Switch branch", executable: "/usr/bin/git",
        fixedArgs: ["checkout", "--"], parameters: [.branch], timeout: 20)

    private func makeParameterizedHarness() -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner()
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  parameterizedCommands: [checkoutSpec])
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         transport: transport, audit: audit, clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner, audit: audit, clock: clock)
    }

    @Test func invalidParameterRepliesWarningAndAuditsWithoutRunning() async {
        let h = makeParameterizedHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/checkout -x"))

        #expect(h.runner.runCount == 0)                 // §4a: validation failure spawns nothing
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("invalid branch name") })
        #expect(h.audit.entries.map(\.event).contains(.rejected(reason: "invalid branch name")))
    }

    @Test func validParameterizedCommandRunsTheResolvedAction() async {
        let h = makeParameterizedHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/checkout main"))

        // I1: the runner receives the resolver-built Action (fixed argv + validated branch), not text.
        let expected = Action(command: "/checkout", description: "Switch branch",
                              executable: "/usr/bin/git", arguments: ["checkout", "--", "main"],
                              timeout: 20)
        #expect(h.runner.runActions == [expected])
    }

    // MARK: - Repo navigation (S16): /cd, /pwd, /repos, and the "select a repo first" gate

    private let relayback = RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                                       scheme: "RelayBack", destination: "platform=macOS")
    private let notes = RepoConfig(name: "notes", root: "/Users/op/dev/Notes")
    private let gitStatusSpec = ParameterizedCommand(
        command: "/gitstatus", description: "Working tree status", executable: "/usr/bin/git",
        fixedArgs: ["status"], parameters: [], timeout: 20, requiresActiveRepo: true)

    /// `repos` defaults to the single `relayback` fixture (a `nil` sentinel keeps the default out of
    /// the signature, since an instance property can't be a default argument value).
    private func makeRepoHarness(repos: [RepoConfig]? = nil) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner()
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  parameterizedCommands: [gitStatusSpec], repoConfigs: repos ?? [relayback])
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         transport: transport, audit: audit, clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner, audit: audit, clock: clock)
    }

    @Test func cdSelectsRepoRepliesAndAuditsWithoutRunning() async {
        let h = makeRepoHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd relayback"))

        #expect(h.runner.runCount == 0)                 // /cd never spawns a process
        #expect(h.transport.sentMessages.contains { $0.text.contains("relayback") && $0.text.contains("/Users/op/dev/RelayBack") })
        #expect(h.audit.entries.map(\.event).contains(.control("cd relayback")))
    }

    // S25: bare `/cd` offers the configured repos as a one-time tap keyboard (names only), never
    // spawning anything, and audits a secret-free "cd prompt" line.
    @Test func bareCdOffersAKeyboardOfConfiguredRepos() async {
        let h = makeRepoHarness(repos: [relayback, notes])
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd"))

        #expect(h.runner.runCount == 0)
        let prompt = h.transport.sentMessages.last
        #expect(prompt?.markup == .keyboard(["relayback", "notes"]))   // one tappable button per repo
        #expect(prompt?.text.lowercased().contains("select a repo") == true)
        #expect(h.audit.entries.map(\.event).contains(.control("cd prompt")))
    }

    // S25: tapping a repo button after the picker (its bare name arrives as the next message) sets
    // the active repo end-to-end — same reply + audit as `/cd <name>`, still no process spawned.
    @Test func tappingARepoButtonAfterTheCdPromptSelectsIt() async {
        let h = makeRepoHarness(repos: [relayback, notes])
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd"))       // picker shown
        await h.coordinator.handle(update(fromId: allowed, text: "notes"))     // tapped button

        #expect(h.runner.runCount == 0)
        #expect(h.transport.sentMessages.contains { $0.text.contains("notes") && $0.text.contains("/Users/op/dev/Notes") })
        #expect(h.audit.entries.map(\.event).contains(.control("cd notes")))
    }

    @Test func repoScopedCommandWithNoActiveRepoWarnsAndDoesNotRun() async {
        let h = makeRepoHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/gitstatus"))

        #expect(h.runner.runCount == 0)                 // §4a precondition unmet → nothing spawns
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("select a repo first") })
        #expect(h.audit.entries.map(\.event).contains(.rejected(reason: "select a repo first")))
    }

    @Test func reposListsConfiguredWithoutLeakingBuildConfig() async {
        let h = makeRepoHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/repos"))

        #expect(h.runner.runCount == 0)
        let reply = h.transport.sentMessages.last?.text ?? ""
        #expect(reply.contains("relayback") && reply.contains("/Users/op/dev/RelayBack"))
        #expect(!reply.contains("platform=macOS"))      // build config is never disclosed
        #expect(h.audit.entries.map(\.event).contains(.control("repos")))
    }

    @Test func updateReposLetsANewlyAddedRepoBeSelected() async {
        let h = makeHarness()   // starts with no configured repos and no parameterized commands
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd relayback"))
        #expect(h.transport.sentMessages.contains { $0.text.contains("unknown repo") })

        h.coordinator.updateRepos([relayback])          // added in Settings, hot-reloaded
        await h.coordinator.handle(update(fromId: allowed, text: "/cd relayback"))
        #expect(h.audit.entries.map(\.event).contains(.control("cd relayback")))
    }

    // MARK: - Multi-step /sim (S19): steps run in order, and the sequence stops on the first failure

    private let simRepo = RepoConfig(name: "app", root: "/Users/op/dev/App",
                                     scheme: "App", destination: "platform=iOS Simulator,name=iPhone 15",
                                     simulatorDevice: "iPhone 15")

    private func makeSimHarness(result: CommandResult = CommandResult(exitCode: 0, stdout: "ok", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner(result: result)
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  repoConfigs: [simRepo], simulatorCommand: SimulatorCommand.spec)
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         transport: transport, audit: audit, clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner, audit: audit, clock: clock)
    }

    private var simSteps: [Action] {
        guard case let .ok(steps) = SimulatorCommand.steps(for: simRepo) else { return [] }
        return steps
    }

    @Test func simRunsEveryStepInOrderAndAuditsEach() async {
        let h = makeSimHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/sim"))

        // I1: the runner receives the config-built step sequence, in order — never operator text.
        #expect(h.runner.runActions == simSteps)
        // I3: each step is audited by the /sim token + its exit code only, never the output.
        #expect(h.audit.entries.filter { $0.event == .actionRan(command: "/sim", exitCode: 0) }.count == 3)
    }

    @Test func simStopsOnFirstNonZeroExit() async {
        let h = makeSimHarness()
        // Step 1 (build) succeeds; step 2 (boot) fails → step 3 (reveal) must never spawn.
        h.runner.scriptedResults = [CommandResult(exitCode: 0, stdout: "built", stderr: ""),
                                    CommandResult(exitCode: 1, stdout: "", stderr: "boot failed")]
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/sim"))

        // Exactly two steps ran — the sequence halted at the first non-zero exit.
        #expect(h.runner.runActions == Array(simSteps.prefix(2)))
        #expect(h.audit.entries.filter { $0.event == .actionRan(command: "/sim", exitCode: 0) }.count == 1)
        #expect(h.audit.entries.filter { $0.event == .actionRan(command: "/sim", exitCode: 1) }.count == 1)
        // I3: no step's captured stdout/stderr ever reaches an audit line — only token + exit code.
        #expect(h.audit.entries.allSatisfy { !$0.line.contains("built") && !$0.line.contains("boot failed") })
    }

    // MARK: - Agent action `/claude` (S21): end-to-end proof of I5

    private let claudeRepo = RepoConfig(name: "app", root: "/Users/op/dev/App")
    private let claudeProfile = ClaudeProfile(executablePath: "/usr/local/bin/claude",
                                              permission: .restricted, timeout: 600)

    /// Builds a coordinator whose `/claude` path is backed by a `FakeClaudeRunner`, so a test can
    /// assert exactly whether the agent runner was reached (I5) and with what prompt/repo/profile.
    private func makeClaudeHarness(enabled: Bool,
                                   result: CommandResult = CommandResult(exitCode: 0, stdout: "claude ok", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner()
        let claudeRunner = FakeClaudeRunner(result: result)
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  repoConfigs: [claudeRepo],
                                  claudeEnabled: enabled, claudeProfile: claudeProfile)
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         claudeRunner: claudeRunner, transport: transport,
                                         audit: audit, clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner,
                       audit: audit, clock: clock, claudeRunner: claudeRunner)
    }

    @Test func claudeEnabledArmedWithRepoRunsViaTheAgentRunner() async {
        let h = makeClaudeHarness(enabled: true)
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/claude summarize the diff"))

        // I5/§4b: the agent runner is reached exactly once, with the prompt (whole), the active-repo
        // root as cwd, and the configured profile — the fixed-action runner is never touched.
        #expect(h.claudeRunner?.runCount == 1)
        #expect(h.runner.runCount == 0)
        let call = h.claudeRunner?.calls.first
        #expect(call?.prompt == "summarize the diff")
        #expect(call?.repoRoot == "/Users/op/dev/App")
        #expect(call?.profile == claudeProfile)

        // FR-6: the agent's output is formatted and delivered like any other run.
        let outputMessages = h.transport.sentMessages.filter { $0.chatId == chat }.map { $0.text }
        #expect(outputMessages.contains { $0.contains("claude ok") && $0.contains("exit 0") })

        // I3/I5: the run is audited by the /claude token + exit code only — never the prompt or output.
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/claude", exitCode: 0) })
        #expect(h.audit.entries.allSatisfy { !$0.line.contains("summarize the diff") && !$0.line.contains("claude ok") })
    }

    @Test func claudeDisabledIsRefusedRunnerNotCalledAndAudited() async {
        let h = makeClaudeHarness(enabled: false)   // default-OFF capability (I5)
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/claude do something"))

        #expect(h.claudeRunner?.runCount == 0)      // I5: disabled → the agent never spawns
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("enable Claude in Settings") })
        #expect(h.audit.entries.map(\.event).contains(.rejected(reason: "enable Claude in Settings")))
    }

    @Test func claudeWithNoActiveRepoIsRefusedAndDoesNotSpawn() async {
        let h = makeClaudeHarness(enabled: true)    // enabled + armed, but no /cd
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/claude do something"))

        #expect(h.claudeRunner?.runCount == 0)      // I5: no active repo → nothing spawns
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("select a repo first") })
        #expect(h.audit.entries.map(\.event).contains(.rejected(reason: "select a repo first")))
    }

    @Test func claudeWhileDisarmedIsRefusedAndDoesNotSpawn() async {
        let h = makeClaudeHarness(enabled: true)    // enabled, but never armed
        await h.coordinator.handle(update(fromId: allowed, text: "/claude do something"))

        #expect(h.claudeRunner?.runCount == 0)      // I2/I5: disarmed → nothing spawns
        #expect(h.transport.sentMessages.first?.text.lowercased().contains("disarm") == true)
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "disarmed")])
    }

    @Test func claudeOversizedOutputSentAsDocument() async {
        let big = String(repeating: "x", count: OutputFormatter.documentThreshold + 1)
        let h = makeClaudeHarness(enabled: true, result: CommandResult(exitCode: 0, stdout: big, stderr: ""))
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/claude big task"))

        #expect(h.transport.sentDocuments.count == 1)   // FR-6: oversized agent output → one document
        #expect(h.transport.sentDocuments.first?.filename == "output.txt")
    }

    @Test func updateClaudeConfigEnablesAPreviouslyRefusedAgentRun() async {
        // S22 hot-reload: the operator flips the capability on in Settings while armed with an active
        // repo; the change reaches the live guard, so the next `/claude` now spawns via the runner.
        let h = makeClaudeHarness(enabled: false)
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
        await h.coordinator.handle(update(fromId: allowed, text: "/claude do it"))
        #expect(h.claudeRunner?.runCount == 0)          // still disabled → nothing spawned yet

        h.coordinator.updateClaudeConfig(enabled: true, profile: claudeProfile)   // toggled in Settings
        await h.coordinator.handle(update(fromId: allowed, text: "/claude do it"))

        #expect(h.claudeRunner?.runCount == 1)          // now the agent runs
        #expect(h.claudeRunner?.calls.last?.profile == claudeProfile)
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/claude", exitCode: 0) })
    }

    // MARK: - Configurable local scripts (/run) — S33

    private var deployScript: ScriptConfig {
        ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy.sh")
    }
    private var backupScript: ScriptConfig {
        ScriptConfig(label: "Backup", path: "/Users/op/bin/backup.sh")
    }

    /// A harness whose registry is seeded from operator-picked scripts (as `AppRuntime` does).
    private func makeScriptHarness(_ scripts: [ScriptConfig],
                                   result: CommandResult = CommandResult(exitCode: 0, stdout: "done", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner(result: result)
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret,
                                  registry: ActionRegistry(actions: scripts.compactMap { $0.toAction() }),
                                  clock: clock, idleTimeout: idleTimeout)
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         transport: transport, audit: audit, clock: clock)
        return Harness(coordinator: coordinator, transport: transport, runner: runner, audit: audit, clock: clock)
    }

    @Test func runSingleScriptRunsItAndAuditsBySlug() async {
        let h = makeScriptHarness([deployScript])
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/run"))

        #expect(h.runner.runActions == [deployScript.toAction()!])   // I1: the configured action, no operator text
        // I3: audit carries the slug command token + exit code only — never the script path.
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/deploy-staging", exitCode: 0) })
    }

    @Test func runSeveralScriptsSendsTheLabelKeyboardAndRunsThePick() async {
        let h = makeScriptHarness([deployScript, backupScript])
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/run"))

        #expect(h.runner.runCount == 0)                              // nothing spawned yet — awaiting the pick
        let prompt = h.transport.sentMessages.last
        #expect(prompt?.markup == .keyboard(["Deploy Staging", "Backup"]))   // labels only
        // I3: the picker discloses labels, never the underlying script paths.
        #expect(!(prompt?.text.contains("/Users/op/bin") ?? false))
        #expect(h.audit.entries.contains { $0.event == .control("run prompt") })

        await h.coordinator.handle(update(fromId: allowed, text: "Backup"))   // tap the label
        #expect(h.runner.runActions == [backupScript.toAction()!])
    }

    @Test func updateActionsEnablesAPreviouslyEmptyRun() async {
        // Hot-reload parity with the allowlist/repos: a script added in Settings reaches the live
        // guard, so the next `/run` now spawns it; a removed one can no longer run (I2).
        let h = makeScriptHarness([])
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/run"))
        #expect(h.runner.runCount == 0)                              // no scripts yet → nothing spawned
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("no scripts configured") })

        h.coordinator.updateActions([deployScript.toAction()!])      // picked a script in Settings
        await h.coordinator.handle(update(fromId: allowed, text: "/run"))

        #expect(h.runner.runActions == [deployScript.toAction()!])
    }

    // MARK: - Release & distribution `/release` + `/pgyer` (S29 — §4c, proof of I1/I2/I3)

    private let pgyerURL = "https://www.pgyer.com/apiv2/app/upload"
    /// A distinctive sentinel so the I3 assertions can search argv/audit/reply for the key's absence.
    private let pgyerKey = "PGYER-SECRET-abc123"

    private var releaseRepo: RepoConfig {
        RepoConfig(name: "app", root: "/Users/op/dev/App",
                   scheme: "App", destination: "platform=macOS",
                   workspace: "App.xcworkspace",
                   exportOptionsPlist: "ExportOptions.plist",
                   uploadArtifact: "build/App.ipa",
                   pgyerDescription: "nightly")
    }

    /// A coordinator wired for `/release`/`/pgyer`: a fully-configured repo, a key provider, and a
    /// fake curl-config writer. `key: nil` drives the missing-key fail-closed path.
    private func makeReleaseHarness(key: String?,
                                    result: CommandResult = CommandResult(exitCode: 0, stdout: "uploaded ok", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner(result: result)
        let audit = InMemoryAuditSink()
        let writer = FakeCurlConfigWriter()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  repoConfigs: [releaseRepo],
                                  releaseCommand: ReleaseCommand.spec,
                                  pgyerCommand: ReleaseCommand.pgyerSpec,
                                  pgyerUploadURL: pgyerURL)
        let coordinator = AppCoordinator(authGuard: authGuard, runner: runner,
                                         transport: transport, audit: audit, clock: clock,
                                         pgyerKeyProvider: { key }, curlConfigWriter: writer)
        return Harness(coordinator: coordinator, transport: transport, runner: runner,
                       audit: audit, clock: clock, curlWriter: writer)
    }

    private func armAndCd(_ h: Harness) async {
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/cd app"))
    }

    @Test func releaseRunsArchiveExportThenUpload() async {
        let h = makeReleaseHarness(key: pgyerKey)
        await armAndCd(h)
        await h.coordinator.handle(update(fromId: allowed, text: "/release"))

        // The three spawns in order: archive, export (both xcodebuild), then the curl upload.
        #expect(h.runner.runActions.count == 3)
        #expect(h.runner.runActions[0].executable == "/usr/bin/xcodebuild")
        #expect(h.runner.runActions[0].arguments.first == "archive")
        #expect(h.runner.runActions[1].arguments.first == "-exportArchive")
        let curl = h.runner.runActions[2]
        #expect(curl.executable == "/usr/bin/curl")
        #expect(curl.arguments == ["--config", "/tmp/relayback-upload-fake.conf", pgyerURL])

        // I3: the key is in the config FILE the writer received — never in the curl argv.
        #expect(h.curlWriter?.writtenBodies.contains { $0.contains(pgyerKey) } == true)
        // The key file is deleted right after the spawn (does not outlive the upload).
        #expect(h.curlWriter?.removedPaths == ["/tmp/relayback-upload-fake.conf"])

        // I3: each of the three runs is audited by the /release token + exit code only (never the
        // key, never the output). Filter to the run events — /arm and /cd add their own control lines.
        let runEvents = h.audit.entries.map(\.event).filter { if case .actionRan = $0 { true } else { false } }
        #expect(runEvents == Array(repeating: .actionRan(command: "/release", exitCode: 0), count: 3))
        #expect(h.audit.entries.allSatisfy { !$0.line.contains(pgyerKey) })
    }

    @Test func releaseKeyNeverAppearsInArgvAuditOrReply() async {
        // The crown-jewel I3 invariant: the sentinel key must appear in NONE of argv / audit / reply,
        // and MUST appear in the config-file body (the one intended channel).
        let h = makeReleaseHarness(key: pgyerKey)
        await armAndCd(h)
        await h.coordinator.handle(update(fromId: allowed, text: "/release"))

        #expect(h.runner.runActions.allSatisfy { action in
            !action.arguments.contains { $0.contains(pgyerKey) } && !action.executable.contains(pgyerKey)
        })
        #expect(h.audit.entries.allSatisfy { !$0.line.contains(pgyerKey) })
        #expect(h.transport.sentMessages.allSatisfy { !$0.text.contains(pgyerKey) })
        #expect(h.curlWriter?.writtenBodies.contains { $0.contains(pgyerKey) } == true)   // the file, yes
    }

    @Test func releaseStopsOnArchiveFailureAndDoesNotUpload() async {
        let h = makeReleaseHarness(key: pgyerKey)
        h.runner.scriptedResults = [CommandResult(exitCode: 65, stdout: "", stderr: "archive failed")]
        await armAndCd(h)
        await h.coordinator.handle(update(fromId: allowed, text: "/release"))

        // Only the archive ran — a failed build never proceeds to export or upload.
        #expect(h.runner.runActions.count == 1)
        #expect(h.runner.runActions[0].arguments.first == "archive")
        #expect(h.curlWriter?.writtenBodies.isEmpty == true)   // no config file → key was never read into one
    }

    @Test func releaseWithMissingKeyRunsBuildsButRefusesUpload() async {
        // The build steps still run (per plan order), but a missing key fails the upload closed — no
        // curl spawn, no config file, a secret-free warning + audit line.
        let h = makeReleaseHarness(key: nil)
        await armAndCd(h)
        await h.coordinator.handle(update(fromId: allowed, text: "/release"))

        #expect(h.runner.runActions.count == 2)                    // archive + export only
        #expect(h.runner.runActions.allSatisfy { $0.executable == "/usr/bin/xcodebuild" })
        #expect(h.curlWriter?.writtenBodies.isEmpty == true)       // fail closed: nothing written
        #expect(h.transport.sentMessages.contains { $0.text.contains("⚠️") && $0.text.contains("no PGYER API key") })
        #expect(h.audit.entries.map(\.event).contains(.rejected(reason: "no PGYER API key configured")))
    }

    @Test func pgyerUploadsTheArtifactWithoutRebuilding() async {
        let h = makeReleaseHarness(key: pgyerKey)
        await armAndCd(h)
        await h.coordinator.handle(update(fromId: allowed, text: "/pgyer"))

        // Exactly one spawn — the curl upload; no xcodebuild.
        #expect(h.runner.runActions.count == 1)
        #expect(h.runner.runActions[0].executable == "/usr/bin/curl")
        #expect(h.curlWriter?.writtenBodies.contains { $0.contains(pgyerKey) } == true)
        // Audited as /pgyer, secret-free.
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/pgyer", exitCode: 0) })
        #expect(h.audit.entries.allSatisfy { !$0.line.contains(pgyerKey) })
    }

    @Test func pgyerWhileDisarmedDoesNotSpawn() async {
        let h = makeReleaseHarness(key: pgyerKey)
        await h.coordinator.handle(update(fromId: allowed, text: "/pgyer"))   // never armed

        #expect(h.runner.runCount == 0)                            // I2: disarmed → nothing spawns
        #expect(h.curlWriter?.writtenBodies.isEmpty == true)
        #expect(h.transport.sentMessages.first?.text.lowercased().contains("disarm") == true)
    }
}
