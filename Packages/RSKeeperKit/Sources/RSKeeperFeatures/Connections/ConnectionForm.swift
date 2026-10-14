import AppKit
import RSKeeperApplication
import RSKeeperDesignSystem
import RSKeeperDomain
import SwiftUI

/// Formulário de conexão (NST-03-03/04/05). A ordem dos campos de servidor segue o SCR-CONN-01 V1:
/// host | porta → TLS (recolhido, onda 2) → usuário | senha → database → SSH (recolhido, onda 3) →
/// somente leitura → Testar / Conectar.
struct ConnectionForm: View {
    @Bindable var model: ConnectionsModel
    @State private var revealPassword = false

    private var errors: [ConnectionDraft.Field: String] {
        model.draft?.validationErrors(for: model.targetKind) ?? [:]
    }

    var body: some View {
        if let binding = Binding($model.draft) {
            ScrollView {
                VStack(alignment: .leading, spacing: RKSpacing.s4) {
                    header(binding)
                    RKTextField(String(localized: "Connection name"), text: binding.name, error: errors[.name])
                        .accessibilityIdentifier("rk.connections.form.name")
                    if model.targetKind == .file {
                        fileFields(binding)
                    } else {
                        serverFields(binding)
                    }
                    Toggle(String(localized: "Read-only connection"), isOn: binding.readOnly)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("rk.connections.form.readOnly")
                    environmentPicker(binding)
                    statusLine
                    actions
                }
                .padding(RKSpacing.s6)
                .frame(maxWidth: 560, alignment: .leading)
            }
            .accessibilityIdentifier("rk.connections.form")
        }
    }

    private func header(_ draft: Binding<ConnectionDraft>) -> some View {
        HStack {
            Text(draft.wrappedValue.isNew ? String(localized: "New connection") : draft.wrappedValue.name)
                .rkTypography(.title2)
            Spacer()
            if let choice = model.driverChoices.first(where: { $0.id == draft.wrappedValue.driverID }) {
                RKBadge(choice.displayName, tone: .accent)
            }
        }
    }

    // MARK: SQLite (NST-03-03)

    private func fileFields(_ draft: Binding<ConnectionDraft>) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.s1) {
            Text(String(localized: "Database file")).rkTypography(.bodyEmphasis)
            HStack {
                Text(draft.wrappedValue.fileGrant?.displayPath ?? String(localized: "No file chosen"))
                    .rkTypography(.code)
                    .foregroundStyle(.rk(draft.wrappedValue.fileGrant == nil ? .textTertiary : .textPrimary))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(String(localized: "Choose…")) {
                    // Só o painel do sistema; caminho digitado não é aceito (crit. 2).
                    Task {
                        if let url = await FilePicker.chooseFile(title: String(localized: "Choose a SQLite database")) {
                            await model.useFile(url)
                        }
                    }
                }
                .buttonStyle(.rk(.secondary))
                .accessibilityIdentifier("rk.connections.form.chooseFile")
            }
            .padding(RKSpacing.s2)
            .background(Color.rk(.surfaceInset), in: RoundedRectangle(cornerRadius: RKRadius.control))
            if let error = errors[.file] {
                Text(error).rkTypography(.caption).foregroundStyle(.rk(.danger))
            }
            Text(String(localized: "You can also drop a .sqlite or .db file here."))
                .rkTypography(.caption).foregroundStyle(.rk(.textSecondary))
        }
    }

    // MARK: Servidor (NST-03-04)

    private func serverFields(_ draft: Binding<ConnectionDraft>) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.s3) {
            HStack(alignment: .top, spacing: RKSpacing.s2) {
                RKTextField(String(localized: "Host"), text: draft.host, monospaced: true, error: errors[.host])
                    .accessibilityIdentifier("rk.connections.form.host")
                RKTextField(String(localized: "Port"), text: draft.port, monospaced: true, error: errors[.port])
                    .frame(width: 110)
                    .accessibilityIdentifier("rk.connections.form.port")
            }
            disabledRow(String(localized: "TLS"), String(localized: "Available in a later version"))
            HStack(alignment: .top, spacing: RKSpacing.s2) {
                RKTextField(String(localized: "User"), text: draft.user, monospaced: true)
                    .accessibilityIdentifier("rk.connections.form.user")
                passwordField(draft)
            }
            RKTextField(String(localized: "Default database"), text: draft.database, monospaced: true)
                .accessibilityIdentifier("rk.connections.form.database")
            disabledRow(String(localized: "SSH tunnel"), String(localized: "Available in a later version"))
            Toggle(String(localized: "Save password in Keychain"), isOn: draft.savePasswords).toggleStyle(.checkbox)
        }
    }

    /// Senha mascarada com botão de revelar [CONFIRMADO CAP-02]. A senha de URL colada nunca aparece.
    private func passwordField(_ draft: Binding<ConnectionDraft>) -> some View {
        Group {
            if draft.wrappedValue.passwordFromURL {
                HStack {
                    Image(systemName: "key.fill").foregroundStyle(.rk(.textSecondary))
                    Text(String(localized: "Password from URL")).rkTypography(.body).foregroundStyle(.rk(.textSecondary))
                    Button(String(localized: "Clear")) { draft.wrappedValue.passwordFromURL = false }.buttonStyle(.rk(.ghost))
                }
            } else {
                HStack(spacing: RKSpacing.s1) {
                    Group {
                        if revealPassword {
                            TextField(String(localized: "Password"), text: draft.password)
                        } else {
                            SecureField(String(localized: "Password"), text: draft.password)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("rk.connections.form.password")
                    Button {
                        revealPassword.toggle()
                    } label: {
                        Image(systemName: revealPassword ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.rk(.ghost))
                    .accessibilityLabel(Text(revealPassword ? String(localized: "Hide password") : String(localized: "Show password")))
                }
            }
        }
    }

    private func disabledRow(_ title: String, _ note: String) -> some View {
        HStack {
            Image(systemName: "chevron.right").foregroundStyle(.rk(.textDisabled))
            Text(title).rkTypography(.body).foregroundStyle(.rk(.textDisabled))
            Spacer()
            Text(note).rkTypography(.caption).foregroundStyle(.rk(.textDisabled))
        }
        .accessibilityElement(children: .combine)
    }

    private func environmentPicker(_ draft: Binding<ConnectionDraft>) -> some View {
        Picker(String(localized: "Environment"), selection: draft.environment) {
            Text(String(localized: "Local")).tag(EnvironmentKind.local)
            Text(String(localized: "Development")).tag(EnvironmentKind.development)
            Text(String(localized: "Testing")).tag(EnvironmentKind.testing)
            Text(String(localized: "Staging")).tag(EnvironmentKind.staging)
            Text(String(localized: "Production")).tag(EnvironmentKind.production)
        }
        .frame(maxWidth: 320)
        .accessibilityIdentifier("rk.connections.form.environment")
    }

    // MARK: Testar e conectar (NST-03-05)

    @ViewBuilder
    private var statusLine: some View {
        switch model.phase {
        case .testing, .connecting:
            HStack(spacing: RKSpacing.s2) {
                RKProgress()
                Text(model.phase == .testing ? String(localized: "Testing connection…") : String(localized: "Connecting…"))
                    .rkTypography(.body)
            }
            .accessibilityIdentifier("rk.connections.form.progress")
        case .succeeded(let message):
            RKInlineBanner(.success, message: message).accessibilityIdentifier("rk.connections.form.result")
        case .failed(let message):
            RKInlineBanner(.error, message: message).accessibilityIdentifier("rk.connections.form.result")
        case .idle:
            EmptyView()
        }
    }

    private var actions: some View {
        HStack(spacing: RKSpacing.s2) {
            if model.phase == .testing || model.phase == .connecting {
                Button(String(localized: "Cancel")) { model.cancel() }
                    .buttonStyle(.rk(.secondary))
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("rk.connections.form.cancel")
            } else {
                Button(String(localized: "Save")) { model.save() }
                    .buttonStyle(.rk(.secondary))
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("rk.connections.form.save")
                Button(String(localized: "Test")) { model.test() }
                    .buttonStyle(.rk(.secondary))
                    .disabled(!model.canSubmit)
                    .accessibilityIdentifier("rk.connections.form.test")
            }
            Spacer()
            Button(String(localized: "Connect")) { model.connect() }
                .buttonStyle(.rk(.primary, isLoading: model.phase == .connecting))
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canSubmit)
                .accessibilityIdentifier("rk.connections.form.connect")
        }
    }
}

/// Seletor de driver (NST-03-02; CAP-03): busca por nome, só os drivers registrados, "Avançar" só com seleção.
struct DriverPickerSheet: View {
    @Bindable var model: ConnectionsModel
    @State private var query = ""
    @State private var selected: DriverID?
    @Environment(\.dismiss) private var dismiss

    private var choices: [DriverChoice] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? model.driverChoices
            : model.driverChoices.filter { $0.displayName.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.s3) {
            Text(String(localized: "Choose a database type")).rkTypography(.title3)
            RKSearchField(String(localized: "Search"), text: $query).accessibilityIdentifier("rk.driverPicker.search")
            List(choices, selection: $selected) { choice in
                HStack {
                    Image(systemName: choice.targetKind == .file ? "doc" : "server.rack").foregroundStyle(.rk(.accent))
                    Text(choice.displayName).rkTypography(.body)
                }
                .tag(choice.id)
                .accessibilityIdentifier("rk.driverPicker.item.\(choice.id.rawValue)")
            }
            .frame(minHeight: 160)
            .onKeyPress(.return) {
                advance()
                return selected == nil ? .ignored : .handled
            }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.buttonStyle(.rk(.secondary)).keyboardShortcut(.cancelAction)
                Button(String(localized: "Next")) { advance() }
                    .buttonStyle(.rk(.primary))
                    .disabled(selected == nil)
                    .accessibilityIdentifier("rk.driverPicker.next")
            }
        }
        .padding(RKSpacing.s6)
        .frame(width: 420)
    }

    private func advance() {
        guard let selected, let choice = model.driverChoices.first(where: { $0.id == selected }) else { return }
        model.choose(choice)
    }
}

/// "Importar de URL" (NST-03-04, crit. 2): colar `postgres://u:p@h:5432/db` preenche os campos.
struct URLImportSheet: View {
    @Bindable var model: ConnectionsModel
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.s3) {
            Text(String(localized: "Import from URL")).rkTypography(.title3)
            RKTextField(String(localized: "postgres://user:password@host:5432/database"), text: $text, monospaced: true)
                .accessibilityIdentifier("rk.urlImport.field")
            if case .failed(let message) = model.phase { RKInlineBanner(.error, message: message) }
            HStack {
                Spacer()
                Button(String(localized: "Cancel")) { dismiss() }.buttonStyle(.rk(.secondary)).keyboardShortcut(.cancelAction)
                Button(String(localized: "Import")) { Task { await model.importURL(text) } }
                    .buttonStyle(.rk(.primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("rk.urlImport.import")
            }
        }
        .padding(RKSpacing.s6)
        .frame(width: 480)
    }
}
