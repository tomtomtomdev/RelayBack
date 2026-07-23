//
//  ScriptConfig.swift
//  RelayBack
//
//  S32 — one entry in the operator-picked local-script allowlist (§4d): a local script **file** the
//  Mac operator selects in Settings and triggers from Telegram via `/run`. Pure value type,
//  persisted (non-secret) via `ConfigStore`.
//
//  Invariant I1 (no shell, ever) holds by construction: `toAction()` produces an ordinary registry
//  `Action` whose `executable` is the script's own absolute `path` (run via its shebang by execve —
//  never `/bin/sh -c`) with an EMPTY argument array. The `path` is only ever the operator's absolute
//  pick from the Settings file browser (`FolderPicking.chooseFile()`), never chat-supplied; a
//  non-absolute or empty path **fails closed** (`toAction()` returns nil) so a bad entry is never
//  runnable. Chat only *selects* among the configured scripts (`/run`, S33) — it never supplies a
//  path, an argument, or script content.
//

import Foundation

struct ScriptConfig: Equatable, Codable, Identifiable {
    /// Operator-facing name shown in the `/run` picker; also the source of the `Action` command token.
    let label: String
    /// Absolute path to the script file (the executable). The only path — never from chat; a
    /// non-absolute value fails closed in `toAction()`.
    let path: String
    /// Absolute working directory for the run, or nil to inherit the launcher's cwd. Operator-picked
    /// (via `FolderPicking.chooseFolder()`), never from chat.
    let workingDirectory: String?
    /// Wall-clock limit handed to the runner (`Process` is terminated if exceeded).
    let timeout: TimeInterval

    /// Default run timeout when a persisted blob omits one (also the memberwise-init default).
    static let defaultTimeout: TimeInterval = 300

    /// Stable identity for SwiftUI lists — the label is unique within the allowlist.
    var id: String { label }

    init(label: String,
         path: String,
         workingDirectory: String? = nil,
         timeout: TimeInterval = ScriptConfig.defaultTimeout) {
        self.label = label
        self.path = path
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    // Custom decode so a minimal/old blob (label + path only) still decodes — `workingDirectory` nil
    // and `timeout` the default — keeping the persisted JSON forward/backward-compatible so a version
    // upgrade never drops the operator's script allowlist (mirrors `RepoConfig`'s tolerance).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        label = try container.decode(String.self, forKey: .label)
        path = try container.decode(String.self, forKey: .path)
        workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        timeout = try container.decodeIfPresent(TimeInterval.self, forKey: .timeout) ?? ScriptConfig.defaultTimeout
    }

    /// Map this config to a fixed-shape registry `Action`, or nil (**fail closed**) when it can't be
    /// run safely. The executable is the script's absolute `path`; the argument array is empty — no
    /// operator text, no shell (I1). Returns nil on a non-absolute/empty path, or a label that slugs
    /// to nothing (which would yield a degenerate command token).
    func toAction() -> Action? {
        guard path.hasPrefix("/") else { return nil }
        let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = Self.slug(name)
        guard !slug.isEmpty else { return nil }
        return Action(command: "/" + slug,
                      description: name,
                      executable: path,
                      arguments: [],
                      timeout: timeout,
                      workingDirectory: workingDirectory)
    }

    /// A lowercase, hyphen-joined slug of the label (alphanumeric runs joined by `-`), used as the
    /// `Action` command token. Empty when the label has no alphanumeric characters.
    static func slug(_ label: String) -> String {
        label.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .joined(separator: "-")
    }
}
