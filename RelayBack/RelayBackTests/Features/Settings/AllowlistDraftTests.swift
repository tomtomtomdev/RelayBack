//
//  AllowlistDraftTests.swift
//  RelayBackTests
//
//  S10 — validation of operator-typed Telegram ids for the allowlist (FR-9). This is what
//  populates the identity gate (invariant I2), so malformed input must never enter the set.
//

import Foundation
import Testing
@testable import RelayBack

struct AllowlistDraftTests {

    @Test func addsAValidPositiveId() {
        var draft = AllowlistDraft()
        #expect(draft.add("42") == .added(42))
        #expect(draft.ids == [42])
    }

    @Test func trimsSurroundingWhitespace() {
        var draft = AllowlistDraft()
        #expect(draft.add("  1007  ") == .added(1007))
        #expect(draft.ids == [1007])
    }

    @Test func rejectsInvalidInput() {
        var draft = AllowlistDraft()
        #expect(draft.add("") == .invalid)
        #expect(draft.add("   ") == .invalid)
        #expect(draft.add("abc") == .invalid)
        #expect(draft.add("4x2") == .invalid)
        #expect(draft.add("3.14") == .invalid)
        #expect(draft.add("99999999999999999999999") == .invalid)   // Int64 overflow
        #expect(draft.ids.isEmpty)
    }

    @Test func rejectsZeroAndNegative() {
        var draft = AllowlistDraft()
        #expect(draft.add("0") == .invalid)
        #expect(draft.add("-5") == .invalid)
        #expect(draft.ids.isEmpty)
    }

    @Test func rejectsDuplicatesWithoutChangingTheSet() {
        var draft = AllowlistDraft([42])
        #expect(draft.add("42") == .duplicate)
        #expect(draft.ids == [42])
    }

    @Test func keepsIdsUniqueAndAscending() {
        var draft = AllowlistDraft([7, 7, 3])   // init dedupes + sorts
        #expect(draft.ids == [3, 7])
        draft.add("5")
        #expect(draft.ids == [3, 5, 7])
    }

    @Test func removesAnId() {
        var draft = AllowlistDraft([1, 2, 3])
        draft.remove(2)
        #expect(draft.ids == [1, 3])
        draft.remove(99)   // absent → no-op
        #expect(draft.ids == [1, 3])
    }
}
