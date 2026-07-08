//
//  AllowlistMemberPresentation.swift
//  RelayBack
//
//  S13e — the pure, testable presentation for one Allowlist-pane member row. The persisted config
//  stores a bare `[Int64]` (option (a), ids-only); the handoff's per-member avatar and `primary`
//  badge are illustrative, so they're derived deterministically from the id here rather than stored.
//  Kept free of SwiftUI so the derivation is unit-tested; the row view is thin glue that maps
//  `avatarGradientIndex` to a `Theme` gradient and renders the initial / id / badge.
//
//  Security note (I2): `isPrimary` is a cosmetic marker on the lowest id only — it does NOT lock
//  removal. Every member, including the primary, stays removable so a compromised id can be revoked
//  immediately (the identity gate, SPEC §4 control 1).
//

import Foundation

struct AllowlistMemberPresentation: Equatable, Identifiable {
    let id: Int64
    /// Cosmetic badge on the lowest id ("your main id"); does not affect removability.
    let isPrimary: Bool

    /// Number of avatar gradients `Theme` provides; `avatarGradientIndex` is always in `0..<this`.
    static let gradientCount = 4

    /// The monospace id label the row shows, e.g. `id 481920774`.
    var idText: String { "id \(id)" }

    /// The avatar's letter — the id's leading digit (ids are positive, so always present).
    var avatarInitial: String { String(String(id).prefix(1)) }

    /// A stable per-id bucket into `Theme.avatarGradients`, so each member keeps a distinct color.
    var avatarGradientIndex: Int { Int(id % Int64(Self.gradientCount)) }

    /// Builds the sorted member rows for an allowlist; the lowest id is the (cosmetic) primary.
    static func rows(for ids: [Int64]) -> [AllowlistMemberPresentation] {
        Array(Set(ids)).sorted().enumerated().map { index, id in
            AllowlistMemberPresentation(id: id, isPrimary: index == 0)
        }
    }
}
