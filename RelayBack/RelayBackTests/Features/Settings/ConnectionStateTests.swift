//
//  ConnectionStateTests.swift
//  RelayBackTests
//
//  S13f — the Settings Connection pane's live state. Two pure surfaces:
//
//  1. `ConnectionStatePresentation(ConnectionState)` — maps `.connecting / .connected(botUsername:)
//     / .error(reason:)` to a (label, detail, style) the view renders. The username is shown as
//     `@name`; an error shows its short, secret-free reason.
//  2. `ConnectionState.probe(_:)` — asks the transport who it is (`getMe`) and derives the state.
//     On failure it reduces the error via `ConnectionReason.from`, which is derived from the error
//     type/code only and never embeds the failing URL (which carries the bot token) — invariant I3.
//

import Foundation
import Testing
@testable import RelayBack

struct ConnectionStateTests {

    // MARK: - Presentation mapping

    @Test func connectingMapsToConnectingStyle() {
        let p = ConnectionStatePresentation(.connecting)
        #expect(p.style == .connecting)
        #expect(p.label == "Connecting…")
    }

    @Test func connectedShowsAtPrefixedUsername() {
        let p = ConnectionStatePresentation(.connected(botUsername: "relayback_bot"))
        #expect(p.style == .connected)
        #expect(p.label == "Connected")
        #expect(p.detail == "@relayback_bot")
    }

    @Test func errorShowsItsReasonAndErrorStyle() {
        let p = ConnectionStatePresentation(.error(reason: "network error -1009"))
        #expect(p.style == .error)
        #expect(p.detail == "network error -1009")
    }

    // MARK: - Probe against the transport

    @Test func probeReturnsConnectedWithUsernameOnSuccess() async {
        let transport = FakeTelegramTransport()
        transport.botUsername = "relayback_bot"
        let state = await ConnectionState.probe(transport)
        #expect(state == .connected(botUsername: "relayback_bot"))
    }

    @Test func probeReducesAFailureToASecretFreeReason() async {
        // A URLError can carry the failing request URL (with the bot token) in its userInfo; the
        // probed error state must reduce to the type/code only and never leak it (invariant I3).
        let token = "123456:AA-super-secret-bot-token"
        let leaky = URL(string: "https://api.telegram.org/bot\(token)/getMe")!
        let transport = FakeTelegramTransport()
        transport.getMeError = URLError(.notConnectedToInternet,
                                        userInfo: [NSURLErrorFailingURLStringErrorKey: leaky.absoluteString])

        let state = await ConnectionState.probe(transport)
        guard case let .error(reason) = state else {
            Issue.record("expected .error, got \(state)")
            return
        }
        #expect(!reason.contains(token))
        #expect(!reason.contains("super-secret"))
        #expect(reason == "network error \(URLError.Code.notConnectedToInternet.rawValue)")
    }
}
