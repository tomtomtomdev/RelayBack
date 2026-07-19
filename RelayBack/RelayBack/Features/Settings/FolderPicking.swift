//
//  FolderPicking.swift
//  RelayBack
//
//  S20 — the native path-chooser seam behind Settings. A repo's working directory (Repos → "Add
//  repo") is selected with a folder browser instead of a hand-typed absolute path, so the operator
//  picks a directory that actually exists rather than risking a typo in the one path the dev-workflow
//  commands run in. S22 extends it with a *file* chooser for the Claude Code executable path (Claude
//  pane), for the same reason: the executable that gets spawned should be a real file the operator
//  pointed at, never a mistyped string. `SettingsModel` opens both through this protocol so the glue
//  is unit-testable against a fake; the real impls are thin AppKit verified by the running app (no
//  test presents a real panel).
//
//  Single selection; the result is an absolute path, or nil if cancelled.
//

import AppKit

/// Presents native `NSOpenPanel` choosers and returns the selected filesystem path.
protocol FolderPicking {
    /// Shows a modal folder browser. Returns the chosen directory's absolute path, or nil if the
    /// operator cancelled.
    func chooseFolder() -> String?
    /// Shows a modal file browser. Returns the chosen file's absolute path, or nil if the operator
    /// cancelled. Used to point at the Claude Code executable (S22).
    func chooseFile() -> String?
}

/// The real chooser, backed by `NSOpenPanel` restricted to a single existing directory or file.
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

    func chooseFile() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the Claude Code executable."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}
