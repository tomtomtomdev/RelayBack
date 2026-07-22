//
//  ActionRegistry.swift
//  RelayBack
//
//  S2 — the fixed allowlist of runnable actions and the lookup that maps an operator's
//  message to one of them.
//
//  Invariant I1 (no shell, ever): matching is a pure lookup by command token. The message
//  text only ever *selects* a pre-defined Action; it is never turned into an executable or
//  argument. Control commands (`/arm`, `/disarm`, `/status`) are deliberately absent — they
//  are session control handled by AuthGuard (S3), not things that spawn a process.
//

import Foundation

struct ActionRegistry {
    let actions: [Action]

    /// Returns the allowlisted action selected by `text`, or nil if none matches.
    ///
    /// Matching uses the **leading whitespace-delimited token**, compared case-insensitively
    /// against each action's `command`. Trailing text is ignored (and never used as an
    /// argument — invariant I1). A token that merely shares a prefix with a command does not
    /// match; the whole token must equal the command.
    func match(_ text: String) -> Action? {
        guard let token = text.split(whereSeparator: \.isWhitespace).first else { return nil }
        let normalized = token.lowercased()
        return actions.first { $0.command.lowercased() == normalized }
    }
}

extension ActionRegistry {
    /// The v1 seed allowlist.
    ///
    /// Deliberately **empty**: the app's runnable surface is now the repo-scoped git/build
    /// commands and the multi-step `/sim` (S16–S19), resolved from operator config — not a
    /// fixed set of read-only system diagnostics. The legacy diagnostics (`/disk`, `/ip`,
    /// `/mem`, `/top`, `/ps`, `/netstat`, `/battery`, `/date`, and earlier `/uptime`,
    /// `/whoami`) were removed; with none seeded, the menu shows its "No actions can run"
    /// state until config-derived commands are wired in.
    ///
    /// Any future entry must remain an absolute path with a fixed argument array (invariant
    /// I1), run as the normal user under a restricted PATH by the runner (invariant I4).
    static let seed = ActionRegistry(actions: [])
}
