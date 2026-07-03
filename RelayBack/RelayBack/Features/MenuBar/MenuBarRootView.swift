//
//  MenuBarRootView.swift
//  RelayBack
//
//  S10 — the menu-bar popover (FR-9). S13a rebuilt the shell to the design handoff: a 368px
//  surface with a brand header + status pill, the disarmed locked-state card, a pulsing
//  "listening" row, a RECENT activity list, and the Settings/Quit footer. S13b added the armed
//  body: allowlisted-action cards (read-only), a dark last-result terminal card, and a "Disarm
//  now" footer button. Rendering only — all state comes from `MenuBarModel` and the pure
//  `MenuBarStatus`; the live values are pushed in by the run loop. Colors/radii come from `Theme`.
//  Verified via the #Previews below. The RECENT rows are color-coded in S13c.
//

import SwiftUI
import AppKit

struct MenuBarRootView: View {
    @Bindable var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.status.isArmed {
                armedBody
            } else {
                disarmedBody
            }
        }
        .frame(width: Theme.popoverWidth, alignment: .leading)
        .background(Theme.popoverSurface)
    }

    // MARK: - Bodies

    private var disarmedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            divider
            lockedCard
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            divider
            listeningRow
            divider
            recentActivity
            divider
            footer
        }
    }

    private var armedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Armed by operator · idle timeout resets on each action.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            actionsSection
            divider.padding(.horizontal, 14)
            lastResultSection
            armedFooter
        }
    }

    private var divider: some View {
        Rectangle().fill(Theme.divider).frame(height: 1)
    }

    // MARK: - Header (brand + status pill)

    private var header: some View {
        HStack(spacing: 10) {
            brandGlyph
            Text("RelayBack")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            statusPill
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var brandGlyph: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.brandGradient)
            .frame(width: 26, height: 26)
            .overlay(
                Image(systemName: "dot.radiowaves.up.forward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            )
    }

    private var statusPill: some View {
        let style = model.status.pillStyle
        return HStack(spacing: 6) {
            PulsingDot(color: style.dot, animates: model.status.isArmed)
            Text(model.status.pillLabel)
                .font(.system(size: 12, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(style.foreground)
            if model.status.showsCountdown {
                Text(model.status.countdown)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(style.foreground)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Theme.armedGreen.opacity(0.12), in: Capsule())
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(style.background, in: Capsule())
    }

    // MARK: - Disarmed locked-state card

    private var lockedCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.disarmedDot)
            VStack(alignment: .leading, spacing: 3) {
                Text("No actions can run")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                HStack(spacing: 0) {
                    Text("Send ")
                    Text("/arm <code>")
                        .font(.system(size: 12, design: .monospaced))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(hex: 0xF0F0F3), in: RoundedRectangle(cornerRadius: 5))
                    Text(" from Telegram")
                }
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .stroke(Theme.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Listening row

    private var listeningRow: some View {
        HStack(spacing: 8) {
            PulsingDot(color: Theme.armedGreen, animates: true)
            Text("Listening for updates")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let bot = model.botUsername {
                Text("@\(bot)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Recent activity

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("RECENT")
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(Theme.textTertiary)
            if model.recentAudit.isEmpty {
                Text("No recent activity.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                ForEach(Array(model.recentAudit.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Armed: allowlisted actions (read-only)

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("ALLOWLISTED ACTIONS")
            ForEach(model.actions) { action in
                HStack(spacing: 11) {
                    Text(action.command)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                    Text(action.description)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Theme.cardBorder, lineWidth: 1)
                )
            }
            HStack(spacing: 6) {
                Image(systemName: "paperplane")
                Text("Trigger from the Telegram chat — the menu shows the registry, read-only.")
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.top, 3)
        }
        .padding(.horizontal, 14)
        .padding(.top, 2)
    }

    // MARK: - Armed: last-result terminal card

    private var lastResultSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("LAST RESULT")
            if let result = model.lastResult {
                lastResultCard(result)
            } else {
                Text("No action has run this session.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    private func lastResultCard(_ result: LastResultPresentation) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(result.commandLine)
                .foregroundStyle(Color(hex: 0x6F7A93))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(result.exitLabel)
                    .foregroundStyle(result.exitIsSuccess ? Theme.terminalGreen : Theme.danger)
                if let first = result.outputLines.first {
                    Text("· \(first)").foregroundStyle(Color(hex: 0xCDD6E8))
                }
            }
            ForEach(Array(result.outputLines.dropFirst().enumerated()), id: \.offset) { _, line in
                Text(line).foregroundStyle(Color(hex: 0xCDD6E8))
            }
        }
        .font(.system(size: 11.5, design: .monospaced))
        .lineSpacing(3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(Theme.terminal, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    // MARK: - Armed footer ("Disarm now" + Settings/Quit)

    private var armedFooter: some View {
        HStack {
            Button(action: model.disarm) {
                Text("Disarm now")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Theme.danger.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            Spacer()
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) { divider }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.6)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// A small dot that gently pulses (opacity + scale) to signal "live", per the handoff's
/// listening/armed indicators. Static when `animates` is false.
private struct PulsingDot: View {
    let color: Color
    var animates: Bool = true
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .opacity(animates ? (on ? 0.35 : 1) : 1)
            .scaleEffect(animates ? (on ? 0.82 : 1) : 1)
            .onAppear {
                guard animates else { return }
                withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                    on = true
                }
            }
    }
}

#Preview("Disarmed") {
    MenuBarRootView(model: MenuBarModel(
        recentAudit: [
            "14:02  /uptime            ok",
            "14:05  /run               rejected · disarmed",
            "14:07  /disk              rejected · unknown id",
        ],
        botUsername: "relayback_bot"
    ))
}

#Preview("Armed") {
    MenuBarRootView(model: MenuBarModel(
        status: MenuBarStatus(isArmed: true, remaining: 278),
        botUsername: "relayback_bot",
        lastResult: LastResultPresentation(
            command: "/uptime",
            result: CommandResult(exitCode: 0,
                                  stdout: "14:32 up 6 days, 2:11\nload avg 1.42 1.20 1.08",
                                  stderr: "")
        )
    ))
}
