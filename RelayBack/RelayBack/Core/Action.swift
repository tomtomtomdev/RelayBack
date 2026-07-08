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
    /// For a parameterized action (§4a) any operator-supplied value has already been validated
    /// and placed at a fixed index here; it never reaches the `executable` slot.
    let arguments: [String]
    /// Wall-clock limit; the runner terminates the process if it is exceeded.
    let timeout: TimeInterval
    /// Absolute working directory for the spawned process, or nil to inherit the launcher's cwd
    /// (the v1 default). Set only to a root drawn from the configured repo allowlist — never from
    /// operator text (§4a). The runner passes it to `Process.currentDirectoryURL`.
    let workingDirectory: String?

    init(command: String,
         description: String,
         executable: String,
         arguments: [String],
         timeout: TimeInterval,
         workingDirectory: String? = nil) {
        self.command = command
        self.description = description
        self.executable = executable
        self.arguments = arguments
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }

    /// Returns a copy with `workingDirectory` set — used by `AuthGuard` to run a dev-workflow
    /// action in the session's active repo root (§4a / S16). The root is drawn only from the
    /// configured repo allowlist, never from operator text.
    func withWorkingDirectory(_ directory: String) -> Action {
        Action(command: command, description: description, executable: executable,
               arguments: arguments, timeout: timeout, workingDirectory: directory)
    }
}
