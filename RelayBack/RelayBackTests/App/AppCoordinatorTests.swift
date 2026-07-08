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
//      selects it (proven by the recorded action equalling the seeded `/uptime`).
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
    }

    private func makeHarness(result: CommandResult = CommandResult(exitCode: 0, stdout: "up 3 days", stderr: "")) -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner(result: result)
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed],
                                  totpSecret: secret,
                                  registry: .seed,
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

    private var uptime: Action { ActionRegistry.seed.match("/uptime")! }

    // MARK: - Authorized + armed action runs and replies with formatted output

    @Test func armedAuthorizedActionRunsAndRepliesFormatted() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

        // I1/I2: exactly one process, and it is the registry action selected by the token.
        #expect(h.runner.runActions == [uptime])

        // FR-6: the formatted result is what OutputFormatter produces, sent as text to the chat.
        let expected = OutputFormatter.format(CommandResult(exitCode: 0, stdout: "up 3 days", stderr: ""))
        let outputMessages = h.transport.sentMessages.filter { $0.chatId == chat }.map { $0.text }
        #expect(outputMessages.contains { $0.contains("up 3 days") && $0.contains("exit 0") })
        #expect(expected.count == 1)   // small output → one text message

        // I3: the run is audited by command token + exit code only — never the output.
        #expect(h.audit.entries.contains { $0.event == .actionRan(command: "/uptime", exitCode: 0) })
        #expect(h.audit.entries.allSatisfy { !$0.line.contains("up 3 days") })
    }

    // MARK: - Unknown user: dropped, nothing run, no reply, rejection audited (I2 / FR-2)

    @Test func unknownUserDroppedNothingRunNoReply() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: stranger, text: "/uptime"))

        #expect(h.runner.runCount == 0)                 // I2: no spawn for a stranger
        #expect(h.transport.sentMessages.isEmpty)       // FR-2: strangers get no reply at all
        #expect(h.transport.sentDocuments.isEmpty)
        #expect(h.audit.entries.map(\.event) == [.rejected(reason: "unknown user")])
    }

    // MARK: - Disarmed action: replied, runner NOT called (I2)

    @Test func disarmedActionRepliesAndDoesNotRun() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

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
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

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

    // MARK: - Oversized output → a single document (FR-6)

    @Test func oversizedOutputSentAsDocument() async {
        let big = String(repeating: "x", count: OutputFormatter.documentThreshold + 1)
        let h = makeHarness(result: CommandResult(exitCode: 0, stdout: big, stderr: ""))
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

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
        await h.coordinator.handle(update(fromId: newcomer, text: "/uptime"))
        #expect(h.runner.runCount == 0)

        h.coordinator.updateAllowlist([allowed, newcomer])
        await h.coordinator.handle(update(fromId: newcomer, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: newcomer, text: "/uptime"))

        // The newly-authorized id armed and ran exactly the registry action (I1/I2).
        #expect(h.runner.runActions == [uptime])
    }

    @Test func updateAllowlistRevokesARemovedId() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))

        h.coordinator.updateAllowlist([])   // remove everyone
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

        #expect(h.runner.runCount == 0)     // I2: a removed id can no longer run, even mid-session
    }

    // MARK: - Disarm hook & last-result push for the popover (S13b)

    @Test func disarmDropsTheLiveSessionSoNothingRuns() async {
        let h = makeHarness()
        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        #expect(h.coordinator.isArmed)

        h.coordinator.disarm()                          // the popover's "Disarm now" target
        #expect(h.coordinator.isArmed == false)

        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))
        #expect(h.runner.runCount == 0)                 // I2: disarmed by the UI → nothing runs
    }

    @Test func onActionCompletedReceivesCommandAndResult() async {
        let h = makeHarness()                           // default result: exit 0, "up 3 days"
        var received: (command: String, result: CommandResult)?
        h.coordinator.onActionCompleted = { received = ($0, $1) }

        await h.coordinator.handle(update(fromId: allowed, text: "/arm \(goodCode(at: h.clock.now))"))
        await h.coordinator.handle(update(fromId: allowed, text: "/uptime"))

        #expect(received?.command == "/uptime")
        #expect(received?.result == CommandResult(exitCode: 0, stdout: "up 3 days", stderr: ""))
    }

    // MARK: - Non-actionable updates are ignored

    @Test func updateWithoutMessageOrSenderOrTextIsIgnored() async {
        let h = makeHarness()
        await h.coordinator.handle(TelegramUpdate(updateId: 1, message: nil))              // no message
        await h.coordinator.handle(update(fromId: nil, text: "/uptime"))                    // no sender (channel post)
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
    private let gitStatusSpec = ParameterizedCommand(
        command: "/gitstatus", description: "Working tree status", executable: "/usr/bin/git",
        fixedArgs: ["status"], parameters: [], timeout: 20, requiresActiveRepo: true)

    private func makeRepoHarness() -> Harness {
        let clock = TestClock(start)
        let transport = FakeTelegramTransport()
        let runner = FakeCommandRunner()
        let audit = InMemoryAuditSink()
        let authGuard = AuthGuard(allowlist: [allowed], totpSecret: secret, registry: .seed,
                                  clock: clock, idleTimeout: idleTimeout,
                                  parameterizedCommands: [gitStatusSpec], repoConfigs: [relayback])
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
}
