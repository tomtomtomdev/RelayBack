//
//  AppRuntime.swift
//  RelayBack
//
//  S11 — the composition root. Like `main()`, this is the one place the real implementations are
//  assembled from concrete types (Keychain, URLSession, Process, the audit file); it holds no
//  decision logic of its own, so it is verified by building + running the app rather than by unit
//  tests (every piece it wires is already tested behind its protocol, or is a thin I/O impl).
//
//  It owns the observable view models the UI binds to (`settings`, `menuBar`) and the polling
//  lifecycle. `start()` builds the coordinator + poll loop from the stored credentials and begins
//  long-polling; with no token/secret configured yet it stays idle (nothing to poll). `stop()`
//  halts polling for a clean shutdown.
//
//  NOTE (deferred): the authorization allowlist is not yet persisted, so a freshly launched agent
//  builds an EMPTY allowlist and therefore authorizes no one (fails closed — safe). Persisting the
//  allowlist and feeding it into the running `AuthGuard` needs a non-secret config store and is
//  tracked in PROGRESS as the next step.
//

import Foundation

@MainActor
@Observable
final class AppRuntime {
    let settings: SettingsModel
    let menuBar = MenuBarModel()

    private let store: SecretStore
    private let idleTimeout: TimeInterval

    private var pollLoop: PollLoop?

    init(store: SecretStore = KeychainStore(), idleTimeout: TimeInterval = 300) {
        self.store = store
        self.idleTimeout = idleTimeout
        self.settings = SettingsModel(store: store)
    }

    /// Begins long-polling if the app is configured (bot token + TOTP secret present). Idempotent —
    /// a second call while already polling is a no-op. Safe to call when unconfigured: it stays idle.
    func start() {
        guard pollLoop == nil else { return }
        guard let token = try? store.botToken(), !token.isEmpty,
              let secret = try? store.totpSecret(), !secret.isEmpty,
              let client = try? TelegramClient(token: token) else {
            return
        }

        let clock = SystemClock()
        let authGuard = AuthGuard(allowlist: Set(settings.allowlist.ids),
                                  totpSecret: secret,
                                  registry: .seed,
                                  clock: clock,
                                  idleTimeout: idleTimeout)

        let sink = MenuBarAuditSink(base: FileAuditLog(fileURL: Self.auditLogURL()), menuBar: menuBar)
        let coordinator = AppCoordinator(authGuard: authGuard,
                                         runner: ProcessCommandRunner(),
                                         transport: client,
                                         audit: sink,
                                         clock: clock)
        sink.status = { [weak coordinator] in
            guard let coordinator else { return MenuBarStatus(isArmed: false, remaining: 0) }
            return MenuBarStatus(isArmed: coordinator.isArmed, remaining: coordinator.remainingArmedTime)
        }

        let loop = PollLoop(transport: client, handler: coordinator)
        pollLoop = loop
        loop.start()

        // Best-effort: advertise the allowlisted commands so they autocomplete in chat (SPEC §5).
        Task { try? await client.setMyCommands(Self.botCommands()) }
    }

    /// Stops long-polling — graceful shutdown (e.g. on app termination). Idempotent.
    func stop() {
        pollLoop?.stop()
        pollLoop = nil
    }

    /// Whether the agent is currently long-polling.
    var isPolling: Bool { pollLoop?.isRunning ?? false }

    // MARK: - Wiring helpers

    /// The autocompleted command list, derived from the action registry plus the control commands.
    private static func botCommands() -> [BotCommand] {
        let actions = ActionRegistry.seed.actions.map {
            BotCommand(command: String($0.command.dropFirst()), description: $0.description)
        }
        let controls = [
            BotCommand(command: "arm", description: "Arm the session with a TOTP code"),
            BotCommand(command: "disarm", description: "Disarm the session"),
            BotCommand(command: "status", description: "Show arm status"),
        ]
        return controls + actions
    }

    /// The append-only audit log location under Application Support (FR-8).
    private static func auditLogURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appending(path: "RelayBack/audit.log")
    }
}
