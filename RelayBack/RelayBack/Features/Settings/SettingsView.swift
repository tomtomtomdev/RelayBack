//
//  SettingsView.swift
//  RelayBack
//
//  S10 — the Settings screen (FR-9): bot-token entry (→ Keychain), allowlist id management, TOTP
//  secret generation shown as a scannable otpauth QR, and a launch-at-login toggle. Rendering and
//  light glue only; all state and validation live in `SettingsModel` / `AllowlistDraft` and are
//  unit-tested. The QR is derived purely from `model.otpauthURI`. Verified via the #Preview below.
//
//  The token is never displayed back (SecureField) and never logged (invariant I3). The
//  launch-at-login toggle is UI only here — `SMAppService` is wired in S11.
//

import SwiftUI
import AppKit
import CoreImage.CIFilterBuiltins

struct SettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            botTokenSection
            allowlistSection
            totpSection
            startupSection
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Bot token

    private var botTokenSection: some View {
        Section("Telegram bot token") {
            SecureField("123456:ABC-DEF…", text: $model.botToken)
            Button("Save token") { model.saveToken() }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - Allowlist

    private var allowlistSection: some View {
        Section("Authorized Telegram IDs") {
            ForEach(model.allowlist.ids, id: \.self) { id in
                HStack {
                    Text(String(id)).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) { model.removeId(id) } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
            if model.allowlist.ids.isEmpty {
                Text("No IDs yet — no one can run commands.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Numeric from.id", text: $model.newIdText)
                    .onSubmit { model.addId() }
                Button("Add") { model.addId() }
                    .disabled(model.newIdText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = model.allowlistError {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
    }

    // MARK: - TOTP secret

    private var totpSection: some View {
        Section("TOTP arming secret") {
            if let uri = model.otpauthURI {
                HStack(alignment: .top, spacing: 16) {
                    qrImage(for: uri)
                        .frame(width: 140, height: 140)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scan into your authenticator app.")
                            .font(.caption).foregroundStyle(.secondary)
                        if let base32 = model.totpSecretBase32 {
                            Text(base32)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(2)
                        }
                        Button("Regenerate", role: .destructive) { model.generateSecret() }
                    }
                }
            } else {
                Text("No secret set. Generate one, then scan it to arm from your phone.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Generate secret") { model.generateSecret() }
            }
        }
    }

    // MARK: - Startup

    private var startupSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            ))
        }
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
        // Scale up so the code isn't blurry at display size.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            return Image(systemName: "qrcode")
        }
        return Image(nsImage: NSImage(cgImage: cgImage, size: NSSize(width: 140, height: 140)))
    }
}

#Preview("Empty") {
    SettingsView(model: SettingsModel(store: PreviewSecretStore()))
}

#Preview("Configured") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(totpSecret: Data("12345678901234567890".utf8)),
        configStore: PreviewConfigStore(allowlist: [42, 1007])
    ))
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
