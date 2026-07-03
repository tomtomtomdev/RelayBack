//
//  PollLoopTests.swift
//  RelayBackTests
//
//  S11 — the polling lifecycle, driven against the transport fake and a spy handler (no network,
//  no real time). These are the executable proof of the lifecycle guarantees:
//    • FR-1 — each poll requests the advanced offset, so no update is ever reprocessed, and an
//      empty batch never rewinds the offset.
//    • Reconnect/backoff — the loop keeps polling across transport failures, waiting the backoff
//      delay between attempts, and resumes normal processing when the transport recovers.
//    • Start/stop are idempotent — a second `start()` never launches a second poller, `stop()`
//      halts polling, and both are safe to call twice.
//

import Foundation
import Testing
@testable import RelayBack

struct PollLoopTests {

    private enum FakeTransportError: Error { case down }

    private func update(_ id: Int64) -> TelegramUpdate {
        TelegramUpdate(updateId: id,
                       message: TelegramMessage(from: TelegramUser(id: 1),
                                                chat: TelegramChat(id: 1),
                                                text: "/status"))
    }

    private func makeLoop(_ transport: FakeTelegramTransport,
                          handler: UpdateHandling,
                          backoff: Backoff = Backoff(),
                          sleep: @escaping (TimeInterval) async throws -> Void = { _ in },
                          connectionLog: ConnectionSink = InMemoryConnectionSink()) -> PollLoop {
        PollLoop(transport: transport, handler: handler, backoff: backoff,
                 sleep: sleep, connectionLog: connectionLog)
    }

    // MARK: - One poll cycle

    @Test func pollOnceDispatchesInOrderAndAdvancesOffset() async throws {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [.updates([update(5), update(7)])]
        let spy = SpyUpdateHandler()
        let loop = makeLoop(transport, handler: spy)

        try await loop.pollOnce()

        #expect(spy.handled.map(\.updateId) == [5, 7])
        #expect(loop.offset == 8)                        // one past the highest update_id
        #expect(transport.getUpdatesOffsets == [0])      // first poll used the initial offset
    }

    @Test func pollOnceNeverReprocesses() async throws {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [.updates([update(5)]), .updates([])]
        let spy = SpyUpdateHandler()
        let loop = makeLoop(transport, handler: spy)

        try await loop.pollOnce()
        try await loop.pollOnce()

        #expect(spy.handled.map(\.updateId) == [5])      // handled exactly once
        #expect(loop.offset == 6)
        #expect(transport.getUpdatesOffsets == [0, 6])   // second poll used the advanced offset
    }

    @Test func pollOnceEmptyBatchLeavesOffsetUnchanged() async throws {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [.updates([])]
        let loop = makeLoop(transport, handler: SpyUpdateHandler())

        try await loop.pollOnce()

        #expect(loop.offset == 0)                        // never rewinds
    }

    // MARK: - Reconnect & backoff

    @Test func runBacksOffOnFailuresThenRecovers() async {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [
            .failure(FakeTransportError.down),
            .failure(FakeTransportError.down),
            .updates([update(5)]),
            // subsequent polls run past the script and block until the loop is stopped
        ]
        let recovered = AsyncSignal()
        transport.onScriptExhausted = { recovered.fire() }
        let spy = SpyUpdateHandler()
        let recorder = SleepRecorder()
        let loop = makeLoop(transport,
                            handler: spy,
                            backoff: Backoff(base: 1, cap: 30, multiplier: 2),
                            sleep: recorder.sleep)

        loop.start()
        await recovered.wait()                           // got past the failures and is polling again
        loop.stop()

        #expect(recorder.delays == [1, 2])               // backoff after the 1st and 2nd failure
        #expect(spy.handled.map(\.updateId) == [5])      // recovered and processed the update once
        #expect(loop.offset == 6)
    }

    // MARK: - Connection-lifecycle logging (persistent)

    @Test func runLogsDisconnectThenReconnectAsTransitions() async {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [
            .failure(FakeTransportError.down),
            .failure(FakeTransportError.down),
            .updates([update(5)]),
            // subsequent polls run past the script and block until the loop is stopped
        ]
        let recovered = AsyncSignal()
        transport.onScriptExhausted = { recovered.fire() }
        let connectionLog = InMemoryConnectionSink()
        let loop = makeLoop(transport, handler: SpyUpdateHandler(), connectionLog: connectionLog)

        loop.start()
        await recovered.wait()
        loop.stop()

        // One disconnect (on the first failure), one reconnect (on recovery) — no duplicate line
        // for the second consecutive failure. Only transitions are logged.
        #expect(connectionLog.entries.map(\.event) == [
            .disconnected(reason: "transport error"),
            .connected,
        ])
    }

    @Test func runLogsConnectedOnceWhileHealthy() async {
        let transport = FakeTelegramTransport()
        transport.getUpdatesScript = [.updates([update(5)]), .updates([])]   // two healthy polls
        let idle = AsyncSignal()
        transport.onScriptExhausted = { idle.fire() }
        let connectionLog = InMemoryConnectionSink()
        let loop = makeLoop(transport, handler: SpyUpdateHandler(), connectionLog: connectionLog)

        loop.start()
        await idle.wait()
        loop.stop()

        // Repeated successful polls do not spam the log — a single "connected" transition.
        #expect(connectionLog.entries.map(\.event) == [.connected])
    }

    // MARK: - Start/stop idempotence

    @Test func startAndStopAreIdempotent() async {
        let transport = FakeTelegramTransport()
        let started = AsyncSignal()
        transport.onScriptExhausted = { started.fire() }   // fires on the first (blocking) poll
        let loop = makeLoop(transport, handler: SpyUpdateHandler())

        #expect(loop.isRunning == false)
        loop.start()
        loop.start()                                    // must not launch a second poller
        #expect(loop.isRunning)

        await started.wait()
        let pollsWhileRunning = transport.getUpdatesOffsets.count
        #expect(pollsWhileRunning == 1)                 // exactly one poller ran

        loop.stop()
        #expect(loop.isRunning == false)
        loop.stop()                                     // safe to call again
        #expect(transport.getUpdatesOffsets.count == pollsWhileRunning)   // no polling after stop
    }
}
