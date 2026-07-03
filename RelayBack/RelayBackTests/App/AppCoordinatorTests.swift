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
}
