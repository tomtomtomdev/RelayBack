//
//  CommandRunning.swift
//  RelayBack
//
//  S7 — the seam between the app's decision logic and process execution (FR-5). `AppCoordinator`
//  (S8) depends on this protocol, so it can be tested against a fake with no real spawning; the
//  real implementation is `ProcessCommandRunner`.
//
//  The method is non-throwing: a run always yields a `CommandResult`. Launch failures and timeouts
//  are folded into that result (non-zero exit + a stderr note) rather than thrown, so the
//  coordinator always has exactly one thing to format, deliver, and audit.
//

import Foundation

protocol CommandRunning {
    /// Spawn `action.executable` with its fixed `arguments`, capture stdout/stderr/exit code, and
    /// terminate the process if it exceeds `action.timeout`. Never interprets operator text (I1).
    func run(_ action: Action) async -> CommandResult
}
