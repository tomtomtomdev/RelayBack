//
//  MenuBarRootView.swift
//  RelayBack
//
//  S10 — the menu-bar popover (FR-9). S13a rebuilt the shell to the design handoff: a 368px
//  surface with a brand header + status pill, the disarmed locked-state card, a pulsing
//  "listening" row, a RECENT activity list, and the Settings/Quit footer. Rendering only — all
//  state comes from `MenuBarModel` and the pure `MenuBarStatus`; the live values are pushed in by
//  the S11 run loop. Colors/radii come from `Theme`. Verified via the #Previews below.
//
//  The armed-only body (allowlisted-action cards + last-result terminal card + "Disarm now") is
//  S13b; the RECENT rows are color-coded in S13c.
//

import SwiftUI
import AppKit

struct MenuBarRootView: View {
    @Bindable var model: MenuBarModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
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
        .frame(width: Theme.popoverWidth, alignment: .leading)
        .background(Theme.popoverSurface)
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
        recentAudit: [
            "14:02  /uptime            ok",
        ],
        botUsername: "relayback_bot"
    ))
}
