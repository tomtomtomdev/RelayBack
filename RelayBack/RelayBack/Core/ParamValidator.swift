//
//  ParamValidator.swift
//  RelayBack
//
//  S15 — the pure validators for the parameterized dev-workflow actions (§4a). Every operator
//  token is checked here before it can reach a fixed `Process` argv index. This does NOT relax
//  invariant I1: there is still no shell, so metacharacters carry no meaning (a commit message of
//  "; rm -rf /" is a literal string). What these guard against is narrower and specific:
//
//    • a value that *begins* with `-` could be read by the executable as a flag → reject it;
//    • a repo name must resolve only against the configured allowlist → no path from chat, so
//      directory traversal is impossible (a "../x" token is simply not a configured key);
//    • a branch/ref name is constrained to a conservative charset so it stays a single argv token.
//
//  Pure functions, TDD'd directly.
//

import Foundation

enum ParamValidator {
    /// Longest accepted commit message, in characters. A generous single-line cap that keeps the
    /// message one argv token and one audit line without truncating ordinary messages.
    static let maxCommitMessageLength = 200

    /// Resolves a repo name against the configured allowlist to its absolute root, or nil if the
    /// name is not configured. Lookup is exact (no case-folding) so a mismatch can never silently
    /// widen access, and — because no path ever comes from chat — traversal is impossible (§4a).
    static func repoName(_ token: String, in repoTable: [String: String]) -> String? {
        repoTable[token]
    }

    /// A git branch/ref name: `^[A-Za-z0-9._/-]+$` and must not begin with `-` (so it can never be
    /// read as a flag). Rejects empty, whitespace, and shell metacharacters (§4a / I1).
    static func branch(_ token: String) -> Bool {
        guard let first = token.first, first != "-" else { return false }
        return token.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._/-".contains($0)) }
    }

    /// A commit message: non-empty, single line, length-capped, and must not begin with `-` (so a
    /// message can never be read as a flag). Metacharacters are permitted — without a shell they
    /// are a literal message — but a newline would break the single argv token and the audit line.
    static func commitMessage(_ token: String, maxLength: Int = maxCommitMessageLength) -> Bool {
        guard let first = token.first, first != "-" else { return false }
        guard token.count <= maxLength else { return false }
        return !token.contains { $0.isNewline }
    }
}
