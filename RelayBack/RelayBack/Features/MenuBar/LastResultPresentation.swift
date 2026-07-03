//
//  LastResultPresentation.swift
//  RelayBack
//
//  S13b — the pure mapping from a finished command run to the armed popover's dark "Last result"
//  terminal card (FR-9): a `$ /cmd` line, an `exit N` label (success vs. failure), and the output
//  split into the lines the card renders. Kept a plain value type (no SwiftUI) so the framing and
//  line-splitting are unit tested directly; the view just renders these fields.
//
//  This is a *local UI* surface, not the audit log: showing output here is intended by the design
//  handoff and does not touch invariant I3 (audit entries and Telegram replies are elsewhere).
//

import Foundation

struct LastResultPresentation: Equatable {
    /// The prompt line, e.g. `$ /uptime`.
    let commandLine: String
    /// The exit-code label, e.g. `exit 0`.
    let exitLabel: String
    /// Whether the run exited cleanly (drives the green vs. red exit color).
    let exitIsSuccess: Bool
    /// The output, split into lines; stdout when present, else stderr; empty when there was none.
    let outputLines: [String]

    init(command: String, result: CommandResult) {
        self.commandLine = "$ \(command)"
        self.exitLabel = "exit \(result.exitCode)"
        self.exitIsSuccess = result.exitCode == 0
        let raw = result.stdout.isEmpty ? result.stderr : result.stdout
        self.outputLines = Self.lines(of: raw)
    }

    /// Splits output into display lines, dropping trailing blank lines from a trailing newline.
    private static func lines(of text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = parts.last, last.isEmpty { parts.removeLast() }
        return parts
    }
}
