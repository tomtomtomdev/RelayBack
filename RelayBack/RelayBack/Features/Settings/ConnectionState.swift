//
//  ConnectionState.swift
//  RelayBack
//
//  S13f — the Settings Connection pane's live transport state, plus its pure presentation.
//
//  `ConnectionState` is a small enum the composition root updates (probing at startup); the pane
//  binds to it via `ConnectionStatePresentation`, which maps it to a (label, detail, style) the
//  view renders. `probe` asks the transport who it is (`getMe`) and derives the state — on failure
//  it reduces the error through `ConnectionReason.from`, which is built from the error type/code
//  only and never embeds the failing URL (which carries the bot token in its path) — invariant I3.
//

import Foundation

/// The transport's live reachability, as shown in the Connection pane.
enum ConnectionState: Equatable {
    case connecting
    case connected(botUsername: String)
    case error(reason: String)
}

extension ConnectionState {
    /// Resolves the current state by identifying the bot behind the token. Secret-free by
    /// construction: a failure is reduced to `ConnectionReason.from` (type/code only, I3).
    static func probe(_ transport: TelegramTransport) async -> ConnectionState {
        do {
            let me = try await transport.getMe()
            return .connected(botUsername: me.username ?? "bot")
        } catch {
            return .error(reason: ConnectionReason.from(error))
        }
    }
}

/// The pure view mapping for the Connection pane.
struct ConnectionStatePresentation: Equatable {
    enum Style: Equatable { case connecting, connected, error }

    let label: String
    let detail: String
    let style: Style

    init(_ state: ConnectionState) {
        switch state {
        case .connecting:
            label = "Connecting…"
            detail = "Reaching Telegram…"
            style = .connecting
        case let .connected(botUsername):
            label = "Connected"
            detail = "@\(botUsername)"
            style = .connected
        case let .error(reason):
            label = "Disconnected"
            detail = reason
            style = .error
        }
    }
}
