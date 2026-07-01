//
//  CommandResult.swift
//  RelayBack
//
//  S4 — the outcome of running an action: exit code plus captured stdout/stderr. A pure value
//  type, so it lives in Core: the OutputFormatter (Core) consumes it and the CommandRunner
//  (Execution, S7) produces it, without Core depending on the I/O layer.
//

import Foundation

struct CommandResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
