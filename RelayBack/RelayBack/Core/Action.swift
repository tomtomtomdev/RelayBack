//
//  Action.swift
//  RelayBack
//
//  S2 — one entry in the fixed execution allowlist. Pure value type.
//
//  Invariant I1 (no shell, ever): an Action names an absolute `executable` path and a fixed
//  `arguments` array. These are the ONLY things ever spawned. Operator text selects an Action
//  by `command`; it is never used as the executable or as an argument.
//

import Foundation

struct Action: Equatable {
    /// The command token that selects this action, including the leading slash (e.g. "/uptime").
    let command: String
    /// Human-readable description (shown in menus / `setMyCommands`).
    let description: String
    /// Absolute path to the executable to spawn. Never derived from operator text.
    let executable: String
    /// Fixed argument array passed to the executable. Never derived from operator text.
    let arguments: [String]
    /// Wall-clock limit; the runner terminates the process if it is exceeded.
    let timeout: TimeInterval
}
