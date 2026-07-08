//
//  SettingsPane.swift
//  RelayBack
//
//  S13d — the Settings window's sidebar navigation model (Connection · Allowlist · Security ·
//  Audit · General), recreating the handoff's macOS sidebar. Pure data: the ordered case list,
//  per-pane title, and SF Symbol the sidebar rows render and the content area switches on. Kept
//  free of SwiftUI so the nav model is unit-tested; the sidebar view is thin glue.
//

import Foundation

enum SettingsPane: String, CaseIterable, Identifiable, Equatable {
    case connection
    case allowlist
    case repos
    case security
    case audit
    case general

    var id: String { rawValue }

    /// The sidebar row label, matching the design handoff.
    var title: String {
        switch self {
        case .connection: return "Connection"
        case .allowlist:  return "Allowlist"
        case .repos:      return "Repos"
        case .security:   return "Security"
        case .audit:      return "Audit"
        case .general:    return "General"
        }
    }

    /// The SF Symbol shown beside the row (handoff icon mapping).
    var systemImage: String {
        switch self {
        case .connection: return "wifi"
        case .allowlist:  return "person.2"
        case .repos:      return "folder"
        case .security:   return "checkmark.shield"
        case .audit:      return "doc.text"
        case .general:    return "gearshape"
        }
    }
}
