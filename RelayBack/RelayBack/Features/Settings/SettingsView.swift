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
    @State private var selection: SettingsPane

    init(model: SettingsModel, initialPane: SettingsPane = .security) {
        self.model = model
        _selection = State(initialValue: initialPane)
    }

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
        case .repos:      reposPane
        case .scripts:    scriptsPane
        case .claude:     claudePane
        case .security:   securityPane
        case .audit:      auditPane
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
    @State private var tokenSaved = false

    /// Persists the bot token and shows a confirmation on success (cleared when the field is edited).
    private func commitToken() {
        model.saveToken()
        tokenSaved = (model.lastError == nil)
    }

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

    // MARK: - Connection pane (S13f — live status + bot token)

    private var connectionPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            paneHeader("Connection", detail: "The private Telegram bot token this agent polls with.")
            connectionStatusCard
            VStack(alignment: .leading, spacing: 8) {
                Text("BOT TOKEN")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(hex: 0x6B7280))
                    .kerning(0.5)
                SecureField("123456:ABC-DEF…", text: $model.botToken)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit { commitToken() }
                    .onChange(of: model.botToken) { tokenSaved = false }
                HStack(spacing: 10) {
                    Button("Save token") { commitToken() }
                        .buttonStyle(PrimaryButtonStyle())
                    if tokenSaved {
                        Label("Saved to Keychain", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.armedGreenText)
                    }
                }
            }
            if let error = model.lastError {
                Text(error).font(.caption).foregroundStyle(Theme.danger)
            }
            Spacer()
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
    }

    private var connectionStatusCard: some View {
        let status = ConnectionStatePresentation(model.connectionState)
        return HStack(spacing: 11) {
            Circle().fill(status.style.color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(status.label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(status.detail)
                    .font(.system(size: 12, design: status.style == .connected ? .monospaced : .default))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
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

    // MARK: - Repos pane (S16 — the §4a working-directory allowlist)
    //
    // The add-repo draft lives on `SettingsModel` (S20) so the folder chooser + name suggestion are
    // unit-tested; the working directory is picked from a native browser, never typed.

    private var reposPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Repos",
                           detail: "Named working directories the dev-workflow commands run in. Select one from Telegram with /cd <name>; git/build/sim run there.")

                VStack(spacing: 8) {
                    ForEach(model.repos) { repo in
                        repoRow(repo)
                    }
                }

                if model.repos.isEmpty {
                    Text("No repos yet — add one below, then /cd <name> from your phone.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                addRepoForm

                if let error = model.repoError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
    }

    private func repoRow(_ repo: RepoConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(repo.root)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if let scheme = repo.scheme {
                    Text("scheme: \(scheme)")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            Spacer(minLength: 8)
            Button("Remove") { model.removeRepo(name: repo.name) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
    }

    private var addRepoForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD REPO")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .kerning(0.5)
            repoField("Name (e.g. relayback)", text: $model.newRepoName)
                .onSubmit { model.submitNewRepo() }
            folderChooserRow
            repoField("Scheme — optional (for /build)", text: $model.newRepoScheme)
            repoField("Destination — optional (for /build)", text: $model.newRepoDestination)
            repoField("Simulator device — optional (for /sim)", text: $model.newRepoSimulator)
            Button("Add repo") { model.submitNewRepo() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.newRepoName.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.newRepoRoot.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    /// The working directory is chosen from a native folder browser (S20), never typed. Shows the
    /// selected path (or a placeholder) next to a "Choose Folder…" button.
    private var folderChooserRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(model.newRepoRoot.isEmpty ? Theme.textTertiary : Theme.accent)
                Text(model.newRepoRoot.isEmpty ? "No folder chosen" : model.newRepoRoot)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(model.newRepoRoot.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))

            Button("Choose Folder…") { model.chooseRepoRoot() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }

    private func repoField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))
    }

    // MARK: - Scripts pane (S34 — the §4d operator-picked local-script allowlist)
    //
    // Thin glue over `SettingsModel`, mirroring the Repos pane. The script file + working directory are
    // picked from native browsers (reusing the `FolderPicking` seam), never typed — so what gets
    // registered is a real file the operator pointed at (chat never supplies a path, arg, or content —
    // §4d / I1). All state/validation lives in the model; this renders it. `/run` selects among them.

    private var scriptsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Scripts",
                           detail: "Local scripts you can trigger from Telegram with /run. Each runs via its own shebang (no shell) as the normal user, only while armed.")

                VStack(spacing: 8) {
                    ForEach(model.scripts) { script in
                        scriptRow(script)
                    }
                }

                if model.scripts.isEmpty {
                    Text("No scripts yet — add one below, then /run from your phone.")
                        .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                }

                addScriptForm

                if let error = model.scriptError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
    }

    private func scriptRow(_ script: ScriptConfig) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "scroll.fill").foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(script.label)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(script.path)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
                if let cwd = script.workingDirectory {
                    Text("cwd: \(cwd)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Button("Remove") { model.removeScript(label: script.label) }
                .buttonStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.danger)
        }
        .padding(.horizontal, 13).padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
    }

    private var addScriptForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADD SCRIPT")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .kerning(0.5)
            repoField("Name (e.g. Deploy Staging)", text: $model.newScriptLabel)
                .onSubmit { model.submitNewScript() }
            scriptChooserRow(icon: "scroll", placeholder: "No script chosen",
                             value: model.newScriptPath, title: "Choose Script…") {
                model.chooseScriptFile()
            }
            scriptChooserRow(icon: "folder", placeholder: "Inherit launcher directory (optional)",
                             value: model.newScriptWorkingDirectory, title: "Choose Folder…") {
                model.chooseScriptWorkingDirectory()
            }
            scriptTimeoutRow
            Button("Add script") { model.submitNewScript() }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(model.newScriptLabel.trimmingCharacters(in: .whitespaces).isEmpty
                          || model.newScriptPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.top, 4)
    }

    /// A picked-path row (script file or working directory): shows the selection (or a placeholder)
    /// next to a chooser button. The value is picked from a native browser, never typed.
    private func scriptChooserRow(icon: String, placeholder: String, value: String,
                                  title: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .foregroundStyle(value.isEmpty ? Theme.textTertiary : Theme.accent)
                Text(value.isEmpty ? placeholder : value)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(value.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))

            Button(title, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
    }

    private var scriptTimeoutRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Timeout").font(.system(size: 13.5))
                Text("The script is terminated if it exceeds this.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Stepper(value: $model.newScriptTimeout, in: 60...3600, step: 60) {
                Text("\(Int(model.newScriptTimeout / 60)) min")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.cardBorder))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
    }

    // MARK: - Claude pane (S22 — the §4b agent-action capability)
    //
    // Thin glue over `SettingsModel`: the toggle, permission picker, executable file chooser, and
    // timeout stepper each go through a model setter that persists + hot-reloads the running guard
    // (S22). `fullBypass` surfaces a red warning so the dangerous profile is never chosen silently
    // (invariant I5). The executable is picked from a file browser (reusing the `FolderPicking` seam),
    // never typed. All state/validation lives in the model; this renders it.

    private var claudePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                paneHeader("Claude agent",
                           detail: "Run a headless Claude Code agent in the active repo from Telegram with /claude <prompt>. Off by default; the prompt is bounded by the permission profile and the repo, not by a validator.")

                claudeEnableCard

                Text("The agent runs only while armed, with a repo selected via /cd, as the normal user.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)

                permissionPicker
                if model.claudeShowsBypassWarning { bypassWarning }
                claudeExecutableRow
                claudeTimeoutRow

                if let error = model.lastError {
                    Text(error).font(.caption).foregroundStyle(Theme.danger)
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        }
    }

    private var claudeEnableCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Enable /claude").font(.system(size: 13.5))
                Text("When on, an armed operator can run a Claude Code agent in the active repo.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: Binding(
                get: { model.claudeEnabled },
                set: { model.setClaudeEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Theme.armedGreen)
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
    }

    private var permissionPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERMISSION PROFILE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .kerning(0.5)
            Picker("", selection: Binding(
                get: { model.claudePermission },
                set: { model.setClaudePermission($0) }
            )) {
                Text("Restricted").tag(ClaudePermissionProfile.restricted)
                Text("Edits in repo").tag(ClaudePermissionProfile.editsInRepo)
                Text("Full bypass").tag(ClaudePermissionProfile.fullBypass)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            Text(claudePermissionSubtitle)
                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }

    private var claudePermissionSubtitle: String {
        switch model.claudePermission {
        case .restricted:  return "Read & search only — no edits, no shell."
        case .editsInRepo: return "Read, search & edit files in the repo; shell disabled."
        case .fullBypass:  return "All permission checks skipped — arbitrary execution scoped to the repo."
        }
    }

    private var bypassWarning: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("Full bypass skips every permission check — the agent can run any command in the active repo. Use only on a repo you fully trust.")
                .font(.system(size: 12.5))
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.danger)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.danger.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.danger.opacity(0.3)))
    }

    /// The executable is chosen from a native file browser (S22), never typed — so the binary that
    /// gets spawned is a real file the operator pointed at.
    private var claudeExecutableRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CLAUDE CODE EXECUTABLE")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color(hex: 0x6B7280))
                .kerning(0.5)
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(model.claudeExecutablePath.isEmpty ? Theme.textTertiary : Theme.accent)
                    Text(model.claudeExecutablePath.isEmpty ? "No executable chosen" : model.claudeExecutablePath)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(model.claudeExecutablePath.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 11).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))

                Button("Choose…") { model.chooseClaudeExecutable() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var claudeTimeoutRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Agent timeout").font(.system(size: 13.5))
                Text("A run is terminated if it exceeds this — an agent turn can take minutes.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 12)
            Stepper(value: Binding(
                get: { model.claudeTimeout },
                set: { model.setClaudeTimeout($0) }
            ), in: 60...3600, step: 60) {
                Text("\(Int(model.claudeTimeout / 60)) min")
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.cardBorder))
            }
        }
        .padding(.horizontal, 13).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.cardBorder))
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

    // MARK: - Audit pane (S13f)

    private var auditPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            paneHeader("Audit log", detail: "Append-only record of every received command.")
                .padding(.bottom, 14)

            auditColumnHeader

            if model.auditRows.isEmpty {
                Text("No activity yet.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 14)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.auditRows) { row in
                            auditRowView(row)
                        }
                    }
                }
            }

            Text("Append-only · no secrets, no full output stored.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                .padding(.top, 12)
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24))
        .onAppear { model.refreshAuditRows() }
    }

    private var auditColumnHeader: some View {
        HStack(spacing: 0) {
            Text("Time").frame(width: 56, alignment: .leading)
            Text("from.id").frame(width: 104, alignment: .leading)
            Text("Action / decision").frame(maxWidth: .infinity, alignment: .leading)
            Text("Exit").frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 11, weight: .semibold))
        .kerning(0.5)
        .textCase(.uppercase)
        .foregroundStyle(Theme.textTertiary)
        .padding(.bottom, 8)
    }

    private func auditRowView(_ row: AuditRowPresentation) -> some View {
        HStack(spacing: 0) {
            Text(row.time)
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 56, alignment: .leading)
            Text(row.fromIdText)
                .foregroundStyle(row.fromIdColor)
                .lineLimit(1).truncationMode(.tail)
                .frame(width: 104, alignment: .leading)
            Text(row.action)
                .foregroundStyle(row.actionColor)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.exitText)
                .fontWeight(row.exitIsSuccess == nil ? .regular : .semibold)
                .foregroundStyle(row.exitColor)
                .frame(width: 48, alignment: .trailing)
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.horizontal, 8).padding(.vertical, 8)
        .background(rowBackground(for: row))
    }

    /// Zebra striping (odd rows tinted) with a severity tint overlaid for warnings/dangers.
    private func rowBackground(for row: AuditRowPresentation) -> some View {
        let zebra = row.id.isMultiple(of: 2) ? Color.clear : Color.black.opacity(0.025)
        return ZStack {
            zebra
            row.rowTint
        }
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
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration) }

    // A nested view so the style can read `\.isEnabled` (ButtonStyle.makeBody can't). Without it a
    // `.disabled(...)` button (e.g. Add repo with an empty field) still painted solid blue and looked
    // clickable while silently doing nothing — which reads as "the button doesn't respond".
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.accent))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
    }
}

private struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration) }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.black.opacity(0.12)))
                .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
        }
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

#Preview("Audit") {
    let model = SettingsModel(store: PreviewSecretStore(),
                              auditReader: PreviewAuditReader())
    model.refreshAuditRows()
    return SettingsView(model: model, initialPane: .audit)
}

#Preview("Repos") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(),
        configStore: PreviewConfigStore(repos: [
            RepoConfig(name: "relayback", root: "/Users/op/dev/RelayBack",
                       scheme: "RelayBack", destination: "platform=macOS"),
            RepoConfig(name: "notes", root: "/Users/op/dev/Notes"),
        ])
    ), initialPane: .repos)
}

#Preview("Scripts") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(),
        configStore: PreviewConfigStore(scripts: [
            ScriptConfig(label: "Deploy Staging", path: "/Users/op/bin/deploy-staging.sh"),
            ScriptConfig(label: "Backup", path: "/Users/op/bin/backup.sh",
                         workingDirectory: "/Users/op/data"),
        ])
    ), initialPane: .scripts)
}

#Preview("Claude — restricted") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(),
        configStore: PreviewConfigStore(claudeEnabled: true, claudeProfile: ClaudeProfile(
            executablePath: "/opt/homebrew/bin/claude", permission: .restricted, timeout: 600))
    ), initialPane: .claude)
}

#Preview("Claude — full bypass warning") {
    SettingsView(model: SettingsModel(
        store: PreviewSecretStore(),
        configStore: PreviewConfigStore(claudeEnabled: true, claudeProfile: ClaudeProfile(
            executablePath: "/opt/homebrew/bin/claude", permission: .fullBypass, timeout: 1200))
    ), initialPane: .claude)
}

#Preview("Connection — connected") {
    let model = SettingsModel(store: PreviewSecretStore())
    model.connectionState = .connected(botUsername: "relayback_bot")
    return SettingsView(model: model, initialPane: .connection)
}

#Preview("Connection — error") {
    let model = SettingsModel(store: PreviewSecretStore())
    model.connectionState = .error(reason: "network error -1009")
    return SettingsView(model: model, initialPane: .connection)
}

/// A throwaway in-memory `SecretStore` so the Settings previews render without the Keychain.
private final class PreviewSecretStore: SecretStore {
    private var token: String?
    private var secret: Data?
    private var pgyerKey: String?
    init(botToken: String? = nil, totpSecret: Data? = nil) { token = botToken; secret = totpSecret }
    func botToken() throws -> String? { token }
    func setBotToken(_ token: String?) throws { self.token = token }
    func totpSecret() throws -> Data? { secret }
    func setTOTPSecret(_ secret: Data?) throws { self.secret = secret }
    func pgyerApiKey() throws -> String? { pgyerKey }
    func setPgyerApiKey(_ key: String?) throws { pgyerKey = key }
}

/// A throwaway in-memory `ConfigStore` so the Settings previews render a populated allowlist / repos /
/// Claude config.
private final class PreviewConfigStore: ConfigStore {
    private var ids: [Int64]
    private var repoConfigs: [RepoConfig]
    private var scriptConfigs: [ScriptConfig]
    private var claudeIsEnabled: Bool
    private var claudeProfileValue: ClaudeProfile
    private var pgyerURL: String?
    init(allowlist: [Int64] = [], repos: [RepoConfig] = [], scripts: [ScriptConfig] = [],
         claudeEnabled: Bool = false, claudeProfile: ClaudeProfile = .default) {
        ids = allowlist; repoConfigs = repos; scriptConfigs = scripts
        claudeIsEnabled = claudeEnabled; claudeProfileValue = claudeProfile
    }
    func allowlist() -> [Int64] { ids }
    func setAllowlist(_ ids: [Int64]) { self.ids = ids }
    func repos() -> [RepoConfig] { repoConfigs }
    func setRepos(_ repos: [RepoConfig]) { repoConfigs = repos }
    func scripts() -> [ScriptConfig] { scriptConfigs }
    func setScripts(_ scripts: [ScriptConfig]) { scriptConfigs = scripts }
    func claudeEnabled() -> Bool { claudeIsEnabled }
    func setClaudeEnabled(_ enabled: Bool) { claudeIsEnabled = enabled }
    func claudeProfile() -> ClaudeProfile { claudeProfileValue }
    func setClaudeProfile(_ profile: ClaudeProfile) { claudeProfileValue = profile }
    func pgyerUploadURL() -> String { Self.resolvedPgyerUploadURL(pgyerURL) }
    func setPgyerUploadURL(_ url: String) { pgyerURL = url }
}

/// A throwaway `AuditReading` so the Audit-pane preview renders a representative, color-coded table.
private struct PreviewAuditReader: AuditReading {
    func recentEntries(limit: Int) -> [AuditEntry] {
        let now = Date(timeIntervalSince1970: 1_000_000)
        return [
            AuditEntry(timestamp: now, fromId: 481920774, event: .control("armed")),
            AuditEntry(timestamp: now, fromId: 481920774, event: .actionRan(command: "/uptime", exitCode: 0)),
            AuditEntry(timestamp: now, fromId: 481920774, event: .actionRan(command: "/disk", exitCode: 1)),
            AuditEntry(timestamp: now, fromId: 481920774, event: .rejected(reason: "disarmed")),
            AuditEntry(timestamp: now, fromId: 995510, event: .rejected(reason: "unknown user")),
        ].suffix(limit)
    }
}
