//
//  FolderPicking.swift
//  RelayBack
//
//  S20 — the folder-chooser seam behind Settings → Repos → "Add repo". A repo's working directory
//  is now selected with a native folder browser instead of a hand-typed absolute path, so the
//  operator picks a directory that actually exists rather than risking a typo in the one path the
//  dev-workflow commands run in. `SettingsModel` opens the chooser through this protocol so the
//  add-repo glue is unit-testable against a fake; the real impl is thin AppKit verified by the
//  running app (no test presents a real panel).
//
//  Directories only, single selection. The result is an absolute path, or nil if cancelled.
//

import AppKit

/// Presents a native folder chooser and returns the selected directory.
protocol FolderPicking {
    /// Shows a modal folder browser. Returns the chosen directory's absolute path, or nil if the
    /// operator cancelled.
    func chooseFolder() -> String?
}

/// The real folder chooser, backed by `NSOpenPanel` restricted to a single existing directory.
struct NSOpenPanelFolderPicker: FolderPicking {
    func chooseFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the repository's working directory."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
