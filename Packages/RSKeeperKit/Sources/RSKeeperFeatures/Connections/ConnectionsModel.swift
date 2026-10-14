import Foundation
import Observation
import RSKeeperApplication
import RSKeeperDomain

/// Rascunho do formulário de conexão (NST-03-03/04). Texto livre até validar; nunca guarda senha
/// colada de URL (essa vai direto para o depósito de uso único).
public struct ConnectionDraft: Equatable, Sendable {
    public var profileID: ProfileID = .generate()
    public var isNew = true
    public var revision = 0
    public var name = ""
    public var driverID: DriverID?
    public var labelColor: LabelColor = .none
    public var environment: EnvironmentKind = .development
    public var readOnly = false
    // Arquivo (SQLite)
    public var fileGrant: FileGrant?
    // Servidor
    public var host = ""
    public var port = ""
    public var user = ""
    public var password = ""
    public var database = ""
    public var savePasswords = true
    /// Senha veio de URL colada (fica fora do campo; mostrada como "senha da URL").
    public var passwordFromURL = false

    public init() {}

    /// Erros em linha (NST-03-04, crit. 3).
    public func validationErrors(for target: TargetKind?) -> [Field: String] {
        var errors: [Field: String] = [:]
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { errors[.name] = String(localized: "Name is required") }
        switch target {
        case .file?:
            if fileGrant == nil { errors[.file] = String(localized: "Choose a database file") }
        case .server?:
            if host.trimmingCharacters(in: .whitespaces).isEmpty { errors[.host] = String(localized: "Host is required") }
            if !port.isEmpty, UInt16(port).map({ $0 >= 1 }) != true { errors[.port] = String(localized: "Port must be between 1 and 65535") }
        case nil:
            errors[.driver] = String(localized: "Choose a database type")
        }
        return errors
    }

    public enum Field: Hashable, Sendable { case name, driver, file, host, port }
}

/// Estado da tela de conexões (NST-03-01…05).
@MainActor
@Observable
public final class ConnectionsModel {
    public enum Phase: Equatable {
        case idle
        case testing
        case connecting
        case succeeded(String)
        case failed(String)
    }

    public private(set) var sidebar: ConnectionSidebarContent = .empty
    public var filter = ""
    /// Perfil selecionado na sidebar; `nil` com rascunho nulo mostra as boas-vindas.
    public var selection: ProfileID?
    public var draft: ConnectionDraft?
    public private(set) var phase: Phase = .idle
    public var showsDriverPicker = false
    public var showsURLImport = false
    public private(set) var driverChoices: [DriverChoice]

    @ObservationIgnored private let service: ConnectionsService
    @ObservationIgnored private let onConnected: @MainActor (ConnectionProfile, SessionID, WindowID) -> Void
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?

    public init(service: ConnectionsService, onConnected: @escaping @MainActor (ConnectionProfile, SessionID, WindowID) -> Void) {
        self.service = service
        self.onConnected = onConnected
        self.driverChoices = service.driverChoices
    }

    /// Começa a observar perfis (mudanças de outras janelas chegam sem recarga; NST-02-03 crit. 4).
    public func start() {
        guard observation == nil else { return }
        let updates = service.sidebarUpdates()
        observation = Task { [weak self] in
            do {
                for try await content in updates { self?.sidebar = content }
            } catch {}
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        work?.cancel()
    }

    // MARK: Sidebar

    /// Filtro por nome (SCR-CONN-02), sem diferenciar maiúsculas e acentos.
    public func filtered(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return profiles }
        return profiles.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    public var selectedProfile: ConnectionProfile? {
        guard let selection else { return nil }
        return sidebar.saved.first { $0.id == selection }
    }

    public func select(_ id: ProfileID?) {
        selection = id
        draft = selectedProfile.map(Self.draft(from:))
        phase = .idle
    }

    public func togglePin(_ profile: ConnectionProfile) {
        let pinned = sidebar.pinned.contains { $0.id == profile.id }
        run { service in try await service.setPinned(profile.id, !pinned) }
    }

    public func delete(_ profile: ConnectionProfile) {
        run { service in try await service.delete(profile) }
        if selection == profile.id { select(nil) }
    }

    // MARK: Nova conexão e importação

    public func newConnection() {
        selection = nil
        draft = nil
        phase = .idle
        showsDriverPicker = true
    }

    public func choose(_ driver: DriverChoice) {
        var draft = ConnectionDraft()
        draft.driverID = driver.id
        draft.environment = driver.targetKind == .file ? .local : .development
        draft.port = driver.id == .postgresql ? "5432" : ""
        self.draft = draft
        showsDriverPicker = false
    }

    public func importURL(_ text: String) async {
        var draft = ConnectionDraft()
        do throws(RSKeeperError) {
            let fields = try await service.importURL(text, depositPasswordFor: draft.profileID)
            draft.driverID = fields.driverID
            draft.host = fields.host ?? ""
            draft.port = fields.port.map(String.init) ?? (fields.driverID == .postgresql ? "5432" : "")
            draft.user = fields.user ?? ""
            draft.database = fields.database ?? ""
            draft.passwordFromURL = fields.hasPassword
            draft.name = fields.host ?? fields.filePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
            draft.environment = fields.driverID == .sqlite ? .local : .development
            selection = nil
            self.draft = draft
            showsURLImport = false
            phase = .idle
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    /// Arquivo do painel ou arrastado (NST-03-03). Preenche o nome se estiver vazio.
    public func useFile(_ url: URL) async {
        do throws(RSKeeperError) {
            let grant = try await service.grantFile(url)
            if draft == nil {
                var new = ConnectionDraft()
                new.driverID = .sqlite
                new.environment = .local
                draft = new
            }
            draft?.fileGrant = grant
            if draft?.name.isEmpty == true { draft?.name = url.deletingPathExtension().lastPathComponent }
            phase = .idle
        } catch {
            phase = .failed(Self.message(error))
        }
    }

    // MARK: Salvar, testar e conectar (NST-03-05)

    public var targetKind: TargetKind? {
        guard let id = draft?.driverID else { return nil }
        return driverChoices.first { $0.id == id }?.targetKind
    }

    public var canSubmit: Bool {
        guard let draft else { return false }
        return draft.validationErrors(for: targetKind).isEmpty && phase != .testing && phase != .connecting
    }

    public func save() {
        guard let draft, let profile = profile(from: draft) else { return }
        run { service in
            let saved = try await service.save(profile, password: draft.password.isEmpty ? nil : draft.password, isNew: draft.isNew)
            await MainActor.run {
                self.selection = saved.id
                self.draft = Self.draft(from: saved)
            }
        }
    }

    public func test() {
        guard let draft, let profile = profile(from: draft) else { return }
        phase = .testing
        let password = draft.password.isEmpty ? nil : draft.password
        let service = self.service
        work = Task { [weak self] in
            do {
                let version = try await service.test(profile, password: password)
                self?.phase = .succeeded(String(localized: "Connected successfully — \(version)"))
            } catch let error as RSKeeperError {
                guard !Task.isCancelled else { return }
                self?.phase = error == .cancelled ? .idle : .failed(Self.message(error))
            } catch {}
        }
    }

    /// Conectar: salva (se for novo), abre a sessão e entrega a janela de workspace (crit. 2).
    public func connect() {
        guard let draft, var profile = profile(from: draft) else { return }
        phase = .connecting
        let service = self.service
        let password = draft.password.isEmpty ? nil : draft.password
        let isNew = draft.isNew
        let window = WindowID.generate()
        work = Task { [weak self] in
            do {
                profile = try await service.save(profile, password: password, isNew: isNew)
                let sessionID = try await service.connector.connect(profile, window: window)
                await service.recordUse(profile.id)
                guard let self else { return }
                self.phase = .idle
                self.selection = profile.id
                self.draft = Self.draft(from: profile)
                self.onConnected(profile, sessionID, window)
            } catch let error as RSKeeperError {
                guard !Task.isCancelled else { return }
                self?.phase = error == .cancelled ? .idle : .failed(Self.message(error))
            } catch {}
        }
    }

    /// Cancela teste ou conexão lentos (crit. 3).
    public func cancel() {
        work?.cancel()
        work = nil
        phase = .idle
    }

    // MARK: Conversões

    private func profile(from draft: ConnectionDraft) -> ConnectionProfile? {
        guard let driverID = draft.driverID, let kind = targetKind else { return nil }
        let target: ConnectionTarget
        switch kind {
        case .file:
            guard let grant = draft.fileGrant else { return nil }
            target = .file(grant, openMode: draft.readOnly ? .readOnly : .readWrite)
        case .server:
            let existing: SecretRef? = if case .server(_, _, _, let password)? = selectedProfile?.target { password } else { nil }
            target = .server(host: draft.host.trimmingCharacters(in: .whitespaces), port: UInt16(draft.port) ?? 5432,
                             user: draft.user.isEmpty ? nil : draft.user,
                             password: draft.passwordFromURL ? .prompt : existing)
        }
        var profile = ConnectionProfile(id: draft.profileID, name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                                        driverID: driverID, labelColor: draft.labelColor, environment: draft.environment,
                                        environmentConfirmed: true, readOnly: draft.readOnly, target: target,
                                        defaultDatabase: draft.database.isEmpty ? nil : draft.database,
                                        savePasswords: draft.savePasswords, revision: draft.revision)
        if let saved = selectedProfile, saved.id == draft.profileID { profile.createdAt = saved.createdAt }
        return profile
    }

    static func draft(from profile: ConnectionProfile) -> ConnectionDraft {
        var draft = ConnectionDraft()
        draft.profileID = profile.id
        draft.isNew = false
        draft.revision = profile.revision
        draft.name = profile.name
        draft.driverID = profile.driverID
        draft.labelColor = profile.labelColor
        draft.environment = profile.environment
        draft.readOnly = profile.readOnly
        draft.savePasswords = profile.savePasswords
        draft.database = profile.defaultDatabase ?? ""
        switch profile.target {
        case .file(let grant, let mode):
            draft.fileGrant = grant
            draft.readOnly = draft.readOnly || mode == .readOnly
        case .server(let host, let port, let user, _):
            draft.host = host
            draft.port = String(port)
            draft.user = user ?? ""
        }
        return draft
    }

    /// Mensagens distintas por tipo de falha (crit. 4), sempre redigidas.
    static func message(_ error: RSKeeperError) -> String {
        switch error {
        case .auth(let message): message.text
        case .connection(let message): String(localized: "Could not reach the server: \(message.text)")
        case .timeout: String(localized: "The connection attempt timed out.")
        case .permission(let message), .validation(let message), .unsupported(let message): message.text
        case .driver(_, let message): message.text
        case .cancelled: String(localized: "Cancelled.")
        default: String(describing: error)
        }
    }

    private func run(_ body: @escaping @Sendable (ConnectionsService) async throws -> Void) {
        let service = self.service
        Task { [weak self] in
            do {
                try await body(service)
            } catch let error as RSKeeperError {
                self?.phase = .failed(Self.message(error))
            } catch {}
        }
    }
}
