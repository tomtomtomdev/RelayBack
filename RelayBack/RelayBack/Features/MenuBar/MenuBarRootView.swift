//
//  MenuBarRootView.swift
//  RelayBack
//
//  S10 — the menu-bar popover (FR-9): current arm status, a short tail of recent audit activity,
//  and quick actions (open Settings, quit). Rendering only — all state comes from `MenuBarModel`
//  and the pure `MenuBarStatus`; the live values are pushed in by the S11 run loop. Verified via
//  the #Preview below.
//

import SwiftUI
import AppKit

struct MenuBarRootView: View {
    @Bindable var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            recentActivity
            Divider()
            actions
        }
        .padding(16)
        .frame(width: 280, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: model.status.isArmed ? "lock.open.fill" : "lock.fill")
                .foregroundStyle(model.status.isArmed ? Color.green : Color.secondary)
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.status.headline)
                    .font(.headline)
                Text(model.status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent activity")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if model.recentAudit.isEmpty {
                Text("No recent activity.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                ForEach(Array(model.recentAudit.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    private var actions: some View {
        HStack {
            SettingsLink {
                Text("Settings…")
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}

#Preview("Disarmed") {
    MenuBarRootView(model: MenuBarModel())
}

#Preview("Armed") {
    MenuBarRootView(model: MenuBarModel(
        status: MenuBarStatus(isArmed: true, remaining: 272),
        recentAudit: [
            "2026-07-03T14:02:11Z from=42 control=\"armed\"",
            "2026-07-03T14:02:39Z from=42 action=/uptime exit=0",
        ]
    ))
}
