//
//  FakeFolderPicker.swift
//  RelayBackTests
//
//  A `FolderPicking` fake so the folder-chooser (Add repo) and file-chooser (Claude executable, S22)
//  glue in `SettingsModel` is testable without presenting a real NSOpenPanel. Each method returns a
//  scripted path (nil simulates the operator cancelling) and records how many times it was asked.
//

import Foundation
@testable import RelayBack

final class FakeFolderPicker: FolderPicking {
    /// The path returned by the next `chooseFolder()`; nil simulates a cancelled chooser.
    var pathToReturn: String?
    /// The path returned by the next `chooseFile()`; nil simulates a cancelled chooser (S22).
    var fileToReturn: String?
    private(set) var chooseCount = 0
    private(set) var chooseFileCount = 0

    init(pathToReturn: String? = nil, fileToReturn: String? = nil) {
        self.pathToReturn = pathToReturn
        self.fileToReturn = fileToReturn
    }

    func chooseFolder() -> String? {
        chooseCount += 1
        return pathToReturn
    }

    func chooseFile() -> String? {
        chooseFileCount += 1
        return fileToReturn
    }
}
