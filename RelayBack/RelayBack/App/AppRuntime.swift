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
        self.settings = SettingsModel(store: store, configStore: configStore,
                                      auditReader: FileAuditReader(fileURL: Self.auditLogURL()))

        // S12: an allowlist edit in Settings both persists (via the config store) and hot-reloads
        // into the running guard, so it takes effect immediately without restarting the agent.
        settings.onAllowlistChanged = { [weak self] ids in
            self?.coordinator?.updateAllowlist(Set(ids))
        }
        // S16: same pattern for the repo allowlist — an edit hot-reloads into the running guard.
        settings.onReposChanged = { [weak self] repos in
            self?.coordinator?.updateRepos(repos)
        }
    }

    /// Begins long-polling if the app is configured (bot token + TOTP secret present). Idempotent —
    /// a second call while already polling is a no-op. Safe to call when unconfigured: it stays idle.
    func start() {
        guard pollLoop == nil else { return }
        guard let token = try? store.botToken(), !token.isEmpty,
              let secret = try? store.totpSecret(), !secret.isEmpty,
              let client = try? TelegramClient(token: token) else {
            // Unconfigured: nothing to poll. Reflect that in the Connection pane (S13f).
            settings.connectionState = .error(reason: "no bot token configured")
            return
        }

        // S13f: identify the bot to show the live connection state + `@username`. Secret-free:
        // a failure is reduced to a type/code-only reason by `ConnectionState.probe` (I3).
        settings.connectionState = .connecting
        Task { [weak self] in
            let state = await ConnectionState.probe(client)
            self?.settings.connectionState = state
            if case let .connected(username) = state { self?.menuBar.botUsername = username }
        }

        let clock = SystemClock()
        // Seed the guard from the persisted allowlist + repos (S12/S16) — the source of truth across
        // launches. S17/S18 wire the git + build commands: each is repo-scoped, so it runs in the
        // active repo selected with `/cd` and refuses until one is chosen (§4a). `/build` additionally
        // draws its scheme/destination from that repo's config.
        let authGuard = AuthGuard(allowlist: Set(configStore.allowlist()),
                                  totpSecret: secret,
                                  registry: .seed,
                                  clock: clock,
                                  idleTimeout: idleTimeout,
                                  parameterizedCommands: GitCommands.all + BuildCommands.all,
                                  repoConfigs: configStore.repos(),
                                  simulatorCommand: SimulatorCommand.spec)

        let sink = MenuBarAuditSink(base: FileAuditLog(fileURL: Self.auditLogURL()), menuBar: menuBar)
        let coordinator = AppCoordinator(authGuard: authGuard,
                                         runner: ProcessCommandRunner(),
                                         transport: client,
                                         audit: sink,
                                         clock: clock)
        self.coordinator = coordinator          // S12: target for hot-reloading the allowlist
        let statusOf: (AppCoordinator?) -> MenuBarStatus = { coordinator in
            guard let coordinator else { return MenuBarStatus(isArmed: false, remaining: 0) }
            return MenuBarStatus(isArmed: coordinator.isArmed, remaining: coordinator.remainingArmedTime)
        }
        sink.status = { [weak coordinator] in statusOf(coordinator) }

        // S13b: feed the armed popover's "Last result" card, and wire "Disarm now" to the live guard.
        coordinator.onActionCompleted = { [weak self] command, result in
            self?.menuBar.lastResult = LastResultPresentation(command: command, result: result)
        }
        menuBar.disarm = { [weak self, weak coordinator] in
            coordinator?.disarm()
            self?.menuBar.status = statusOf(coordinator)   // reflect the drop immediately
        }

        let loop = PollLoop(transport: client,
                            handler: coordinator,
                            connectionLog: FileConnectionLog(fileURL: Self.connectionLogURL()),
                            clock: clock)
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

    /// The autocompleted command list, derived from the action registry, the control commands, and
    /// the parameterized git + build commands (S17/S18) plus the multi-step `/sim` (S19).
    /// `dropFirst()` strips the leading slash Telegram adds.
    private static func botCommands() -> [BotCommand] {
        let actions = ActionRegistry.seed.actions.map {
            BotCommand(command: String($0.command.dropFirst()), description: $0.description)
        }
        var dev = (GitCommands.all + BuildCommands.all).map {
            BotCommand(command: String($0.command.dropFirst()), description: $0.description)
        }
        dev.append(BotCommand(command: String(SimulatorCommand.spec.command.dropFirst()),
                              description: SimulatorCommand.spec.description))
        let controls = [
            BotCommand(command: "arm", description: "Arm the session with a TOTP code"),
            BotCommand(command: "disarm", description: "Disarm the session"),
            BotCommand(command: "status", description: "Show arm status"),
            BotCommand(command: "repos", description: "List configured repos"),
            BotCommand(command: "cd", description: "Select the active repo"),
            BotCommand(command: "pwd", description: "Show the active repo"),
        ]
        return controls + actions + dev
    }

    /// The append-only audit log location under Application Support (FR-8).
    private static func auditLogURL() -> URL {
        supportDirectory().appending(path: "RelayBack/audit.log")
    }

    /// The append-only connection-lifecycle log location under Application Support (kept separate
    /// from the command audit log so each stays single-purpose).
    private static func connectionLogURL() -> URL {
        supportDirectory().appending(path: "RelayBack/connection.log")
    }

    private static func supportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }
}
