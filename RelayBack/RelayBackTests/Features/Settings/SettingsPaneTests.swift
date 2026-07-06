//
//  SettingsPaneTests.swift
//  RelayBackTests
//
//  S13d — the Settings sidebar's navigation model. The pane list, order, titles, and SF Symbols
//  are pure data the sidebar renders and the content area switches on, so they're pinned here; the
//  SwiftUI sidebar itself is thin glue verified by Preview.
//

import Foundation
import Testing
@testable import RelayBack

struct SettingsPaneTests {

    @Test func listsAllPanesInSidebarOrder() {
        #expect(SettingsPane.allCases == [.connection, .allowlist, .security, .audit, .general])
    }

    @Test func mapsEachPaneToItsHandoffTitle() {
        #expect(SettingsPane.connection.title == "Connection")
        #expect(SettingsPane.allowlist.title == "Allowlist")
        #expect(SettingsPane.security.title == "Security")
        #expect(SettingsPane.audit.title == "Audit")
        #expect(SettingsPane.general.title == "General")
    }

    @Test func mapsEachPaneToAnSFSymbol() {
        #expect(SettingsPane.connection.systemImage == "wifi")
        #expect(SettingsPane.allowlist.systemImage == "person.2")
        #expect(SettingsPane.security.systemImage == "checkmark.shield")
        #expect(SettingsPane.audit.systemImage == "doc.text")
        #expect(SettingsPane.general.systemImage == "gearshape")
    }

    @Test func identifiesByRawValue() {
        #expect(SettingsPane.security.id == "security")
    }
}
