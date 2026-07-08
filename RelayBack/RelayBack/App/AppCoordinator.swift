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

    /// Called after an action finishes, with its command token and result — the runtime wires this
    /// to push the popover's "Last result" card (S13b). Optional so tests/headless runs need not set it.
    var onActionCompleted: ((String, CommandResult) -> Void)?

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

    /// Applies a runtime repo-allowlist change to the live guard (S16), mirroring `updateAllowlist`.
    /// A repo added/removed in Settings takes effect immediately; a removed active repo is dropped.
    func updateRepos(_ repos: [RepoConfig]) {
        authGuard.updateRepos(repos)
    }

    /// Disarms the live session on demand (S13b — the popover's "Disarm now" button). A subsequent
    /// action is blocked until the operator re-arms via TOTP (invariant I2).
    func disarm() {
        authGuard.disarm()
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

        case let .invalidParameters(reason):
            // §4a: a parameter failed validation — warn the operator and audit it; nothing spawns.
            // The reason is short and secret-free (built by ParamValidator/the resolver, never from
            // captured output or a secret), so it is safe in both the reply and the audit line (I3).
            await reply(chatId, "⚠️ \(reason)")
            record(fromId: fromId, event: .rejected(reason: reason))

        case let .control(result):
            await handleControl(result, fromId: fromId, chatId: chatId)

        case let .runAction(action):
            await run(action, fromId: fromId, chatId: chatId)

        case let .runActionSequence(actions):
            // §4a / S19: a multi-step command (`/sim`) — run each config-built step in order,
            // stopping at the first failure. Same per-step reply/audit contract as a single run.
            await runSequence(actions, fromId: fromId, chatId: chatId)
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
        case let .activeRepoSet(repo):
            await reply(chatId, "📁 Active repo: \(repo.name)\n\(repo.root)")
            record(fromId: fromId, event: .control("cd \(repo.name)"))
        case let .workingDirectory(repo):
            await reply(chatId, RepoListPresentation.pwd(repo))
            record(fromId: fromId, event: .control("pwd"))
        case let .repoList(repos):
            await reply(chatId, RepoListPresentation.list(repos))
            record(fromId: fromId, event: .control("repos"))
        }
    }

    // MARK: - Running an action (the only path that spawns a process — I2)

    private func run(_ action: Action, fromId: Int64, chatId: Int64) async {
        _ = await runStep(action, fromId: fromId, chatId: chatId)
    }

    /// Runs a multi-step action sequence (§4a / S19 — `/sim`) in order, stopping at the first step
    /// that exits non-zero so a failed build never proceeds to boot/reveal. Each step goes through
    /// the same `runStep`, so it is formatted, delivered, and audited (I3) exactly like a single
    /// action; the steps come only from the guard's config-built sequence (I1) — no text is interpreted.
    private func runSequence(_ actions: [Action], fromId: Int64, chatId: Int64) async {
        for action in actions {
            let result = await runStep(action, fromId: fromId, chatId: chatId)
            if result.exitCode != 0 { break }   // halt the sequence at the first failing step
        }
    }

    /// Spawns one action, delivers its formatted output, and audits it; returns the result so a
    /// caller (the `/sim` sequence) can decide whether to continue. The only place a process runs (I2).
    private func runStep(_ action: Action, fromId: Int64, chatId: Int64) async -> CommandResult {
        let result = await runner.run(action)          // I1: fixed Action from the guard, no operator text
        for outgoing in OutputFormatter.format(result) {
            await send(outgoing, to: chatId)
        }
        // I3: only the command token + exit code are recorded — never the captured output.
        record(fromId: fromId, event: .actionRan(command: action.command, exitCode: result.exitCode))
        // S13b: feed the popover's last-result card (local UI only — not the audit log / Telegram).
        onActionCompleted?(action.command, result)
        return result
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
