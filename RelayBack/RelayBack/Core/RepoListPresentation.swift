//
//  RepoListPresentation.swift
//  RelayBack
//
//  S16 — pure Telegram-reply text for the repo-navigation commands (`/repos`, `/pwd`). Kept out of
//  the coordinator so the "what is disclosed" rule is a tested unit, not view glue.
//
//  Disclosure rule: only a repo's **name and root** ever go to chat. The per-repo build config
//  (`scheme` / `destination` / `simulatorDevice`) is internal and is deliberately NOT echoed — the
//  `/repos` and `/pwd` replies must never leak anything beyond name/root (asserted by tests).
//

import Foundation

enum RepoListPresentation {
    /// The prompt shown above the `/cd` repo picker (S25). A fixed string — no secret, no path.
    static let selectPrompt = "📁 Select a repo:"

    /// The `/cd` picker button labels (S25): one per configured repo, disclosing ONLY the name —
    /// never the root or build config (even less than `/repos`, which shows name + root). The
    /// coordinator maps these to a one-time reply keyboard the operator taps.
    static func pickerButtons(_ repos: [RepoConfig]) -> [String] {
        repos.map(\.name)
    }

    /// The `/repos` reply: the configured repo allowlist as name + root, one block per repo.
    static func list(_ repos: [RepoConfig]) -> String {
        guard !repos.isEmpty else { return "No repos configured." }
        return repos.map(block).joined(separator: "\n\n")
    }

    /// The `/pwd` reply: the active repo (name + root), or a prompt to select one.
    static func pwd(_ repo: RepoConfig?) -> String {
        guard let repo else { return "No active repo — send /cd <repo> first." }
        return block(repo)
    }

    /// One repo rendered as name + root only (never the build config).
    private static func block(_ repo: RepoConfig) -> String {
        "📁 \(repo.name)\n\(repo.root)"
    }
}
