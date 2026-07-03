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
//  The authorization allowlist is persisted through a `ConfigStore` (S12): `start()` seeds the
//  `AuthGuard` from the saved allowlist, and edits made in Settings are both persisted and
//  hot-reloaded into the running guard via `settings.onAllowlistChanged`, so an id added/removed
//  in Settings takes effect immediately without a restart (a removed id is revoked at once — I2).
//

import Foundation

@MainActor
@Observable
final class AppRuntime {
    let settings: SettingsModel
    let menuBar = MenuBarModel()

    private let store: SecretStore
    private let configStore: ConfigStore
    private let idleTimeout: TimeInterval

    private var pollLoop: PollLoop?
    private var coordinator: AppCoordinator?

    init(store: SecretStore = KeychainStore(),
         configStore: ConfigStore = UserDefaultsConfigStore(),
         idleTimeout: TimeInterval = 300) {
        self.store = store
        self.configStore = configStore
        self.idleTimeout = idleTimeout
        self.settings = SettingsModel(store: store, configStore: configStore)

        // S12: an allowlist edit in Settings both persists (via the config store) and hot-reloads
        // into the running guard, so it takes effect immediately without restarting the agent.
        settings.onAllowlistChanged = { [weak self] ids in
            self?.coordinator?.updateAllowlist(Set(ids))
        }
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
        // Seed the guard from the persisted allowlist (S12) — the source of truth across launches.
        let authGuard = AuthGuard(allowlist: Set(configStore.allowlist()),
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
        self.coordinator = coordinator          // S12: target for hot-reloading the allowlist
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
        coordinator = nil
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
