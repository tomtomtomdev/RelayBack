//
//  AppCoordinator.swift
//  RelayBack
//
//  S8 — the orchestration brain. It owns no I/O directly: every external dependency is an
//  injected protocol (transport, runner, audit sink, clock), so the whole decision-and-reply
//  path is unit-testable against fakes. It wires one received update through:
//
//      transport update → AuthGuard (identity + arm gate) → [ActionRegistry match, inside guard]
//        → CommandRunning (only when .runAction) → OutputFormatter → transport reply
//        → AuditSink (every outcome)
//
//  Security invariants enforced here end-to-end:
//    • I2 — `runner.run` is reached ONLY on `.runAction`, i.e. an allowlisted sender with an
//      armed session. Unknown user / disarmed / bad code / unknown command never spawn anything.
//    • I1 — the runner is handed the registry `Action` the guard resolved; operator text only
//      ever selected it. No text becomes an executable or argument.
//    • I3 — audit entries are built from the decision + exit code only; command output and
//      secrets never enter them (the `AuditEvent` taxonomy has no field that could hold them).
//
//  Isolation: this is a MainActor-isolated class (the project's default actor isolation), not a
//  bespoke `actor`. That keeps it consistent with the rest of the codebase and free of Sendable
//  friction with the fakes, while still never blocking the UI — `ProcessCommandRunner` dispatches
//  its blocking work off-main (S7), and every dependency call here is `await`ed, so `handle`
//  suspends rather than stalling the main thread.
//

import Foundation

final class AppCoordinator {
    private var authGuard: AuthGuard
    private let runner: CommandRunning
    private let transport: TelegramTransport
    private let audit: AuditSink
    private let clock: Clock

    init(authGuard: AuthGuard,
         runner: CommandRunning,
         transport: TelegramTransport,
         audit: AuditSink,
         clock: Clock) {
        self.authGuard = authGuard
        self.runner = runner
        self.transport = transport
        self.audit = audit
        self.clock = clock
    }

    /// Whether the session is currently armed — read by the menu bar to show live arm state (S11).
    var isArmed: Bool { authGuard.isArmed }

    /// Seconds left in the armed window (0 when disarmed) — feeds the menu-bar countdown (S11).
    var remainingArmedTime: TimeInterval { authGuard.remainingArmedTime }

    /// Applies a runtime allowlist change to the live guard (S12). Called when the operator edits
    /// the allowlist in Settings, so identity changes take effect immediately without a restart —
    /// a removed id is revoked at once (I2). Arm state is preserved (see `AuthGuard.updateAllowlist`).
    func updateAllowlist(_ ids: Set<Int64>) {
        authGuard.updateAllowlist(ids)
    }

    /// Routes one received update: authorize, act only if `.runAction`, reply, and audit the
    /// outcome. Non-actionable updates (no message / no sender / no text) are ignored silently —
    /// they can't be authorized (the allowlist matches on `from.id`) and warrant no audit line.
    func handle(_ update: TelegramUpdate) async {
        guard let message = update.message,
              let fromId = message.from?.id,
              let text = message.text else { return }
        let chatId = message.chat.id

        switch authGuard.authorize(fromId: fromId, text: text) {
        case .rejectedUnknownUser:
            // FR-2 / I2: a stranger gets no reply at all — only an audit line.
            record(fromId: fromId, event: .rejected(reason: "unknown user"))

        case .disarmed:
            await reply(chatId, "🔒 Session is disarmed — send /arm <code> first.")
            record(fromId: fromId, event: .rejected(reason: "disarmed"))

        case .unknownCommand:
            await reply(chatId, "❓ Unknown command.")
            record(fromId: fromId, event: .rejected(reason: "unknown command"))

        case let .control(result):
            await handleControl(result, fromId: fromId, chatId: chatId)

        case let .runAction(action):
            await run(action, fromId: fromId, chatId: chatId)
        }
    }

    // MARK: - Control replies

    private func handleControl(_ result: ControlResult, fromId: Int64, chatId: Int64) async {
        switch result {
        case .armAccepted:
            await reply(chatId, "🔓 Armed.")
            record(fromId: fromId, event: .control("armed"))
        case .armRejected:
            await reply(chatId, "❌ Invalid code.")
            record(fromId: fromId, event: .rejected(reason: "bad code"))
        case .disarmAccepted:
            await reply(chatId, "🔒 Disarmed.")
            record(fromId: fromId, event: .control("disarmed"))
        case let .status(isArmed):
            await reply(chatId, "Status: \(isArmed ? "armed" : "disarmed").")
            record(fromId: fromId, event: .control("status armed=\(isArmed)"))
        }
    }

    // MARK: - Running an action (the only path that spawns a process — I2)

    private func run(_ action: Action, fromId: Int64, chatId: Int64) async {
        let result = await runner.run(action)          // I1: fixed registry Action, no operator text
        for outgoing in OutputFormatter.format(result) {
            await send(outgoing, to: chatId)
        }
        // I3: only the command token + exit code are recorded — never the captured output.
        record(fromId: fromId, event: .actionRan(command: action.command, exitCode: result.exitCode))
    }

    // MARK: - Transport & audit helpers

    private func send(_ message: OutgoingMessage, to chatId: Int64) async {
        switch message {
        case let .text(text):
            await reply(chatId, text)
        case let .document(name, data):
            try? await transport.sendDocument(chatId: chatId, filename: name, data: data)
        }
    }

    private func reply(_ chatId: Int64, _ text: String) async {
        // Best-effort: a failed send must not crash update handling (the loop keeps polling).
        try? await transport.sendMessage(chatId: chatId, text: text)
    }

    private func record(fromId: Int64, event: AuditEvent) {
        audit.append(AuditEntry(timestamp: clock.now, fromId: fromId, event: event))
    }
}
