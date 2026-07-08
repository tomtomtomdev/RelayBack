//
//  SettingsView.swift
//  RelayBack
//
//  S10 → S13d — the Settings window (FR-9). Reshaped from a single grouped `Form` into the design
//  handoff's macOS **sidebar window** (Connection · Allowlist · Security · Audit · General): a 176px
//  sidebar swaps the content pane. S13d builds the **Security** pane to spec (QR card, SECRET
//  (BASE32) + Copy, Regenerate / Show otpauth://, the Keychain-assurance banner, and the
//  display-only Idle-timeout / Drift-tolerance rows). The other panes keep the existing controls
//  reachable and are restyled to the handoff in S13e (Allowlist, General) and S13f (Connection, Audit).
//
//  Rendering and light glue only; all state and validation live in `SettingsModel` /
//  `AllowlistDraft` / `SettingsPane` / `ArmingConfigPresentation` and are unit-tested. The QR is
//  derived purely from `model.otpauthURI`. Copy-to-pasteboard and the otpauth reveal are thin glue.
//
//  The token is never displayed back (SecureField) and never logged (invariant I3); secrets flow
//  only through the `SecretStore` seam. Idle-timeout / drift rows are display-only (SPEC pins the
//  TOTP config fixed) — see the decision in PROGRESS.md.
//

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var selection: SettingsPane = .security

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Theme.settingsContent)
        }
        .frame(width: 660, height: 520)
        .background(Theme.settingsWindow)
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(SettingsPane.allCases) { pane in
                sidebarRow(pane)
            }
            Spacer()
        }
        .padding(10)
        .frame(width: 176)
        .background(Theme.settingsSidebar)
    }

    private func sidebarRow(_ pane: SettingsPane) -> some View {
        let isActive = selection == pane
        return Button {
            selection = pane
        } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.systemImage)
                    .frame(width: 16)
                Text(pane.title)
                    .font(.system(size: 13.5))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 7)
            .padding(.horizontal, 9)
            .foregroundStyle(isActive ? Color.white : Color(hex: 0x3A3A3C))
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(isActive ? Theme.accent : Color.clear)
                    .shadow(color: isActive ? Theme.accent.opacity(0.4) : .clear, radius: 3, y: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content router

    @ViewBuilder private var content: some View {
        switch selection {
        case .connection: connectionPane
        case .allowlist:  allowlistPane
        case .security:   securityPane
        case .audit:      placeholderPane("Audit log", detail: "Coming in S13f.")
        case .general:    generalPane
        }
    }

    // MARK: - Security pane (S13d)

    private var securityPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                paneHeader("TOTP arming",
                           detail: "Scan the QR into your authenticator app, then arm from Telegram with /arm <code>.")

                if let uri = model.otpauthURI {
                    qrCard(for: uri)
                    secretField
                    keychainBanner
                    HStack(spacing: 10) {
                        Button("Regenerate secret") { model.generateSecret() }
                            .buttonStyle(PrimaryButtonStyle())
                        Button(showsOtpauth ? "Hide otpauth://" : "Show otpauth://") {
                            showsOtpauth.toggle()
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if showsOtpauth {
                        Text(uri)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder))
                    }
                    Divider().padding(.vertical, 2)
                    armingRows
                } else {
                    keychainBanner
                    Text("No secret set. Generate one, then scan it to arm from your phone.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    Button("Generate secret") { model.generateSecret() }
                        .buttonStyle(PrimaryButtonStyle())
                }

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
    }

    @State private var showsOtpauth = false

    private func qrCard(for uri: String) -> some View {
        qrImage(for: uri)
            .interpolation(.none)
            .resizable()
            .frame(width: 126, height: 126)
            .padding(11)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.window).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.window).stroke(Theme.cardBorder))
    }

    private var secretField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SECRET (BASE32)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .kerning(0.5)
            HStack {
                Text(model.totpSecretBase32 ?? "—")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Copy") { copyToPasteboard(model.totpSecretBase32 ?? "") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.cardBorder))
        }
    }

    private var keychainBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            Text("Secret stored in Keychain — never on disk or in logs.")
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.armedGreenText)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.armedGreen.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.armedGreen.opacity(0.25)))
    }

    private var armingRows: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Idle timeout").font(.system(size: 13.5))
                Spacer()
                Text(model.armingConfig.idleTimeoutText)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.cardBorder))
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Drift tolerance").font(.system(size: 13.5))
                    Text(model.armingConfig.driftSubtitle)
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                // Display-only: reflects the fixed config (SPEC-pinned), so it never toggles.
                Toggle("", isOn: .constant(model.armingConfig.driftIsEnabled))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Theme.armedGreen)
                    .disabled(true)
            }
        }
    }

    // MARK: - Connection pane (bot token — restyled fully in S13f)

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            paneHeader("Connection", detail: "The private Telegram bot token this agent polls with.")
            SecureField("123456:ABC-DEF…", text: $model.botToken)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 360)
            Button("Save token") { model.saveToken() }
                .buttonStyle(PrimaryButtonStyle())
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
    }

    // MARK: - Allowlist pane (S13e)

    private var allowlistPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Allowlist",
                           detail: "Updates are checked against numeric message.from.id — never chat id. Non-matches are dropped silently.")

                VStack(spacing: 8) {
                    ForEach(AllowlistMemberPresentation.rows(for: model.allowlist.ids)) { member in
                        memberRow(member)
                    }
                }

                if model.allowlist.ids.isEmpty {
                    Text("No IDs yet — no one can run commands.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                addIdRow

                if let error = model.allowlistError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
    }

    private func memberRow(_ member: AllowlistMemberPresentation) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.avatarGradients[member.avatarGradientIndex % Theme.avatarGradients.count])
                    .frame(width: 32, height: 32)
                Text(member.avatarInitial)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
            }
            Text(member.idText)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
            Spacer(minLength: 8)
            if member.isPrimary {
                Text("primary")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.armedGreenText)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(Theme.armedGreen.opacity(0.12)))
            }
            // I2: the primary badge is cosmetic — every id, including primary, stays removable.
            Button("Remove") { model.removeId(member.id) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
    }

    private var addIdRow: some View {
        HStack(spacing: 9) {
            TextField("Add numeric id…", text: $model.newIdText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))
                .onSubmit { model.addId() }
            Button("Add") { model.addId() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.newIdText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: - General pane (S13e)

    private var generalPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneHeader("General", detail: "Startup behavior.")
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Launch at login").font(.system(size: 13.5))
                    Text("Start RelayBack automatically when you log in, so the agent is always listening.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.armedGreen)
            }
            .padding(.horizontal, 13).padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))

            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
    }

    // MARK: - Shared bits

    private func paneHeader(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text(detail).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func placeholderPane(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            paneHeader(title, detail: detail)
            Spacer()
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    // MARK: - QR rendering

    /// Renders `string` as a QR code. Pure derivation of the (already pure) otpauth URI; failure
    /// to render just shows an SF Symbol placeholder rather than crashing.
    private func qrImage(for string: String) -> Image {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else {
            return Image(systemName: "qrcode")
        }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return Image(systemName: "qrcode")
        }
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 126, height: 126)))
    }
}

// MARK: - Button styles (handoff primary/secondary)

private struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

#Preview("Security — configured") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(totpSecret: Data("12345678901234567890".utf8)),
        configStore: PreviewConfigStore(allowlist: [481920774, 729104388])
    ))
}

#Preview("Security — empty") {
    SettingsView(model: SettingsModel(store: PreviewSecretStore()))
}

/// A throwaway in-memory `SecretStore` so the Settings previews render without the Keychain.
private final class PreviewSecretStore: SecretStore {
    private var token: String?
    private var secret: Data?
    init(botToken: String? = nil, totpSecret: Data? = nil) { token = botToken; secret = totpSecret }
    func botToken() throws -> String? { token }
    func setBotToken(_ token: String?) throws { self.token = token }
    func totpSecret() throws -> Data? { secret }
    func setTOTPSecret(_ secret: Data?) throws { self.secret = secret }
}

/// A throwaway in-memory `ConfigStore` so the Settings previews render a populated allowlist.
private final class PreviewConfigStore: ConfigStore {
    private var ids: [Int64]
    init(allowlist: [Int64] = []) { ids = allowlist }
    func allowlist() -> [Int64] { ids }
    func setAllowlist(_ ids: [Int64]) { self.ids = ids }
}
