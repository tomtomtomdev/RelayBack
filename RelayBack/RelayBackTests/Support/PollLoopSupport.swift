//
//  PollLoopSupport.swift
//  RelayBackTests
//
//  Test doubles for the S11 polling-loop tests: a spy that records dispatched updates, a sleep
//  recorder that captures backoff delays without ever waiting, and a one-shot async signal used to
//  synchronize the test with the (otherwise infinite) run loop. All main-actor isolated, like the
//  code under test — no real time passes.
//

import Foundation
@testable import RelayBack

/// Records the updates the poll loop dispatched, in order, so a test can assert each was handled
/// exactly once (FR-1: no reprocessing).
final class SpyUpdateHandler: UpdateHandling {
    private(set) var handled: [TelegramUpdate] = []
    func handle(_ update: TelegramUpdate) async { handled.append(update) }
}

/// A `sleep` double that records the requested delays and returns immediately — backoff behavior
/// is asserted on the recorded durations, and tests never actually wait.
final class SleepRecorder {
    private(set) var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws { delays.append(seconds) }
}

/// A one-shot signal to bridge the async run loop and the synchronous test body: the loop `fire()`s
/// when it reaches a known point (via a transport hook) and the test `await`s `wait()`.
final class AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false

    func wait() async {
        if fired { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func fire() {
        guard !fired else { return }
        fired = true
        continuation?.resume()
        continuation = nil
    }
}
