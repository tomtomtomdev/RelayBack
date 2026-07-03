//
//  ActionSummary.swift
//  RelayBack
//
//  S13b — a read-only summary of an allowlisted action for the armed popover's ALLOWLISTED ACTIONS
//  cards (FR-9). It deliberately carries ONLY the command token and description — no `executable`,
//  `arguments`, or `timeout`. The menu is a read-only view of the registry (execution is
//  Telegram-only in v1), so nothing at the UI edge holds a runnable payload (invariant I1).
//

import Foundation

struct ActionSummary: Equatable, Identifiable {
    let command: String
    let description: String

    var id: String { command }

    init(_ action: Action) {
        self.command = action.command
        self.description = action.description
    }
}
