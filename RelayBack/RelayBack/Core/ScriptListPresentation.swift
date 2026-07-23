//
//  ScriptListPresentation.swift
//  RelayBack
//
//  S33 — pure Telegram-reply text for the `/run` script picker (§4d). Kept out of the coordinator
//  so the "what is disclosed" rule is a tested unit, not view glue (mirrors `RepoListPresentation`).
//
//  Disclosure rule: only a script's operator-facing **label** (the `Action.description`) ever goes
//  to chat — never its underlying executable path. The picker buttons and prompt must leak nothing
//  else (asserted by tests, invariant I3).
//

import Foundation

enum ScriptListPresentation {
    /// The prompt shown above the `/run` script picker. A fixed string — no path, no secret.
    static let selectPrompt = "🧩 Select a script to run:"

    /// The `/run` picker button labels: one per configured script, disclosing ONLY the label. The
    /// coordinator maps these to a one-time reply keyboard the operator taps; the tapped label is
    /// consumed by the guard as the script to run (never a path or argument — I1/I3).
    static func pickerButtons(_ actions: [Action]) -> [String] {
        actions.map(\.description)
    }
}
