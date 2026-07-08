//
//  AllowlistMemberPresentationTests.swift
//  RelayBackTests
//
//  S13e — the pure presentation mapping the Allowlist pane renders per member row. Option (a)
//  (ids-only) keeps the config a bare `[Int64]`; the handoff's avatar initial, gradient, and
//  `primary` badge are derived deterministically from the id here, so the SwiftUI row stays thin
//  glue. Removal semantics are unchanged (I2) — `primary` is a cosmetic marker, not a lock.
//

import Foundation
import Testing
@testable import RelayBack

struct AllowlistMemberPresentationTests {

    @Test func buildsRowsSortedWithLowestIdPrimary() {
        let rows = AllowlistMemberPresentation.rows(for: [729104388, 481920774])
        #expect(rows.map(\.id) == [481920774, 729104388])
        #expect(rows[0].isPrimary == true)
        #expect(rows[1].isPrimary == false)
    }

    @Test func emptyAllowlistYieldsNoRows() {
        #expect(AllowlistMemberPresentation.rows(for: []).isEmpty)
    }

    @Test func singleMemberIsPrimary() {
        let rows = AllowlistMemberPresentation.rows(for: [42])
        #expect(rows.count == 1)
        #expect(rows[0].isPrimary)
    }

    @Test func rendersIdWithMonoLabel() {
        #expect(AllowlistMemberPresentation(id: 481920774, isPrimary: true).idText == "id 481920774")
    }

    @Test func avatarInitialIsTheLeadingDigitOfTheId() {
        #expect(AllowlistMemberPresentation(id: 481920774, isPrimary: true).avatarInitial == "4")
        #expect(AllowlistMemberPresentation(id: 729104388, isPrimary: false).avatarInitial == "7")
    }

    @Test func avatarGradientIsAStableInRangeBucketOfTheId() {
        let row = AllowlistMemberPresentation(id: 481920774, isPrimary: true)
        #expect(row.avatarGradientIndex == Int(481920774 % Int64(AllowlistMemberPresentation.gradientCount)))
        #expect((0..<AllowlistMemberPresentation.gradientCount).contains(row.avatarGradientIndex))
    }
}
