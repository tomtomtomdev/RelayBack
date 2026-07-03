//
//  PollLoop.swift
//  RelayBack
//
//  S11 — the lifecycle brain: the long-poll loop that pulls updates from the Telegram transport and
//  feeds each to the coordinator, running unattended for the app's lifetime. It owns the polling
//  offset (FR-1: never reprocess an update) and the reconnect behavior (survive a network blip or a
//  sleep/wake without crashing), keeping both testable against the transport fake — no live network,
//  no real waiting (the sleep is injected).
//
//  The loop depends on `UpdateHandling`, not the concrete `AppCoordinator`, so the dispatch and
//  offset logic can be driven by a spy in tests. `AppCoordinator` conforms below.
//
//  Isolation: MainActor-isolated (the project default). `start()` launches one unstructured `Task`
//  that inherits the main actor; the actual waiting happens inside `transport.getUpdates` (a
//  server-side long poll) and the injected `sleep`, both of which suspend rather than block the UI.
//

import Foundation

/// The seam the poll loop dispatches each received update through. `AppCoordinator` is the real
/// implementation; a spy stands in for it in tests.
protocol UpdateHandling {
    func handle(_ update: TelegramUpdate) async
}

final class PollLoop {
    private let transport: TelegramTransport
    private let handler: UpdateHandling
    private let backoff: Backoff
    private let sleep: (TimeInterval) async throws -> Void

    /// The next `getUpdates` offset — one past the highest `update_id` processed so far (FR-1).
    private(set) var offset: Int64 = 0
    /// Whether a polling task is currently active.
    private(set) var isRunning = false

    private var task: Task<Void, Never>?

    init(transport: TelegramTransport,
         handler: UpdateHandling,
         backoff: Backoff = Backoff(),
         sleep: @escaping (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
         }) {
        self.transport = transport
        self.handler = handler
        self.backoff = backoff
        self.sleep = sleep
    }

    /// Starts the polling task. Idempotent: a second call while already running is a no-op, so there
    /// is never more than one poller (which would double-process updates).
    func start() {
        guard task == nil else { return }
        isRunning = true
        task = Task { [weak self] in
            await self?.run()
        }
    }

    /// Stops polling. Idempotent and safe to call when not running. Cancels the in-flight long poll
    /// (or backoff sleep), which unwinds the loop.
    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    /// The loop body: poll, and on a transport failure wait the backoff delay and retry, until the
    /// task is cancelled. Cancellation (from `stop()`) surfaces as a thrown `CancellationError` from
    /// the in-flight call and ends the loop cleanly — no crash across a sleep/wake or network blip.
    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            do {
                try await pollOnce()
                failures = 0
            } catch is CancellationError {
                break
            } catch {
                failures += 1
                do {
                    try await sleep(backoff.delay(afterFailures: failures))
                } catch {
                    break   // cancelled while backing off
                }
            }
        }
    }

    /// One poll cycle: fetch the batch at the current offset, dispatch each update in order, and
    /// advance the offset past them (an empty batch leaves it unchanged — never rewinds). Throws if
    /// the transport throws, so the caller can back off.
    func pollOnce() async throws {
        let updates = try await transport.getUpdates(offset: offset)
        for update in updates {
            await handler.handle(update)
        }
        offset = TelegramUpdate.nextOffset(after: offset, in: updates)
    }
}

extension AppCoordinator: UpdateHandling {}
