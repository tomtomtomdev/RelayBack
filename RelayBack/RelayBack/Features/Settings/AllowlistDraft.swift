//
//  AllowlistDraft.swift
//  RelayBack
//
//  S10 — the pure, testable core of allowlist id management in Settings (FR-9). It holds the set
//  of numeric Telegram `from.id` values being edited and validates operator input before it can
//  enter the set. Kept a plain value type (no SwiftUI, no I/O) so the validation and set rules are
//  unit-tested directly; the SwiftUI Settings view and the @Observable `SettingsModel` drive it.
//
//  Security note: this is what populates the identity allowlist (SPEC §4 control 1 / invariant I2).
//  Only a well-formed positive integer is accepted — Telegram user ids are positive `from.id`
//  values — so malformed input can never silently widen who may run commands.
//

import Foundation

struct AllowlistDraft: Equatable {
    /// The current allowlist ids, kept unique and in ascending order for stable display.
    private(set) var ids: [Int64]

    init(_ ids: [Int64] = []) {
        self.ids = Array(Set(ids)).sorted()
    }

    /// Outcome of trying to add typed text to the draft.
    enum AddResult: Equatable {
        case added(Int64)
        case invalid      // empty, non-numeric, non-positive, or out of Int64 range
        case duplicate    // already present; the set is unchanged
    }

    /// Validates `text` and inserts it. Accepts only a positive integer; rejects empty /
    /// non-numeric / non-positive / overflowing input, and reports duplicates without mutating.
    @discardableResult
    mutating func add(_ text: String) -> AddResult {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let id = Int64(trimmed), id > 0 else { return .invalid }
        guard !ids.contains(id) else { return .duplicate }
        ids.append(id)
        ids.sort()
        return .added(id)
    }

    /// Removes `id` if present; a no-op otherwise.
    mutating func remove(_ id: Int64) {
        ids.removeAll { $0 == id }
    }
}
