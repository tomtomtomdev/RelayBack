//
//  FakeFolderPicker.swift
//  RelayBackTests
//
//  A `FolderPicking` fake so the "Add repo" folder-chooser glue in `SettingsModel` is testable
//  without presenting a real NSOpenPanel. It returns a scripted path (nil simulates the operator
//  cancelling) and records how many times it was asked.
//

import Foundation
@testable import RelayBack

final class FakeFolderPicker: FolderPicking {
    /// The path returned by the next `chooseFolder()`; nil simulates a cancelled chooser.
    var pathToReturn: String?
    private(set) var chooseCount = 0

    init(pathToReturn: String? = nil) { self.pathToReturn = pathToReturn }

    func chooseFolder() -> String? {
        chooseCount += 1
        return pathToReturn
    }
}
