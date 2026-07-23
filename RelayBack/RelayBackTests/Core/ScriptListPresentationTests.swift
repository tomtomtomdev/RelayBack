//
//  ScriptListPresentationTests.swift
//  RelayBackTests
//
//  S33 — the pure `/run` picker text. The security-relevant property is disclosure: only a
//  script's operator-facing **label** may reach chat; its underlying executable path must never
//  leak into a button or the prompt (I3). These assert that directly.
//

import Foundation
import Testing
@testable import RelayBack

struct ScriptListPresentationTests {

    // Actions carrying a distinctive path sentinel a leak would surface (built as ScriptConfig would).
    private func action(label: String, path: String) -> Action {
        ScriptConfig(label: label, path: path).toAction()!
    }

    @Test func pickerButtonsAreLabelsInOrderOnly() {
        let buttons = ScriptListPresentation.pickerButtons([
            action(label: "Deploy Staging", path: "/Users/op/bin/DEPLOY_SENTINEL.sh"),
            action(label: "Backup", path: "/Users/op/bin/BACKUP_SENTINEL.sh"),
        ])
        #expect(buttons == ["Deploy Staging", "Backup"])
        #expect(!buttons.contains { $0.contains("SENTINEL") })    // no path leaked into a button
    }

    @Test func selectPromptCarriesNoPath() {
        #expect(!ScriptListPresentation.selectPrompt.contains("/"))
    }
}
