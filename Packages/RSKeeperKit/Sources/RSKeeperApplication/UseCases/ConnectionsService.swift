import Foundation
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperPersistence
import RSKeeperSecurity
import RSKeeperSQLKit

/// Driver disponível para o seletor (NST-03-02): só valores, sem expor o protocolo de driver à UI.
public struct DriverChoice: Hashable, Sendable, Identifiable {
    public let id: DriverID
    public let displayName: String
    public let targetKind: TargetKind
    public let supportsTLS: Bool
    public let supportsSSH: Bool
}

/// Campos extraídos de uma URL colada (NST-03-04; F-CONN-09). A senha **não** vem aqui: vai direto
/// para o depósito de uso único e não volta ao campo como texto (AR-IPC-08).
public struct ImportedConnectionFields: Hashable, Sendable {
    public let driverID: DriverID
    public let host: String?
    public let port: UInt16?
    public let user: String?
    public let database: String?
    public let filePath: String?
    public let tlsMode: TLSOptions.Mode?
    public let hasPassword: Bool
    public let ignoredParameters: [String]
}

/// Fachada da tela de conexões (NST-03-01…05): a UI não toca em persistência, segurança nem drivers.
public struct ConnectionsService: Sendable {
    private let profiles: ProfileRepository
    private let drivers: DriverRegistry
    private let fileGrants: FileGrantService
    private let secrets: SecretStore
    private let transient: TransientSecrets
    private let connectUseCase: ConnectUseCase
    private let resolver: any TargetResolving

    public init(profiles: ProfileRepository, drivers: DriverRegistry, fileGrants: FileGrantService, secrets: SecretStore,
                transient: TransientSecrets, connectUseCase: ConnectUseCase, resolver: any TargetResolving) {
        self.profiles = profiles
        self.drivers = drivers
        self.fileGrants = fileGrants
        self.secrets = secrets
        self.transient = transient
        self.connectUseCase = connectUseCase
        self.resolver = resolver
    }

    // MARK: Sidebar e drivers

    public func sidebarUpdates() -> AsyncThrowingStream<ConnectionSidebarContent, any Error> { profiles.sidebarUpdates() }

    public var driverChoices: [DriverChoice] {
        drivers.descriptors.map {
            DriverChoice(id: $0.id, displayName: $0.displayName, targetKind: $0.targetKind,
                         supportsTLS: $0.capabilities.tls, supportsSSH: $0.capabilities.ssh)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Perfis

    /// Salva um perfil novo ou editado. Se houver senha digitada e o perfil guardar senhas, ela vai para
    /// o Keychain ligada à impressão do alvo; senão, fica só no depósito de uso único.
    @discardableResult
    public func save(_ profile: ConnectionProfile, password: String?, isNew: Bool) async throws(RSKeeperError) -> ConnectionProfile {
        var profile = profile
        guard !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .validation(RedactedMessage(alreadyRedacted: "Dê um nome à conexão."))
        }
        if case .server(let host, let port, let user, let current) = profile.target {
            var reference = current
            if let password, !password.isEmpty {
                if profile.savePasswords {
                    do {
                        reference = try await secrets.store(password, for: SecretKey(profileID: profile.id, purpose: .password),
                                                            fingerprint: TargetFingerprinter.fingerprint(of: profile))
                    } catch {
                        throw .permission(RedactedMessage(alreadyRedacted: "Não foi possível guardar a senha no Keychain."))
                    }
                } else {
                    reference = .prompt
                    await transient.deposit(password, for: profile.id)
                }
            }
            profile.target = .server(host: host, port: port, user: user, password: reference)
        }
        if isNew {
            try await profiles.insert(profile)
            return profile
        }
        return try await profiles.update(profile, expectedRevision: profile.revision)
    }

    public func delete(_ profile: ConnectionProfile) async throws(RSKeeperError) {
        try await profiles.delete(profile.id, expectedRevision: profile.revision)
        try? await secrets.deleteAll(for: profile.id)
    }

    public func setPinned(_ id: ProfileID, _ pinned: Bool) async throws(RSKeeperError) {
        try await profiles.setPinned(id, pinned)
    }

    /// Concessão a partir do arquivo escolhido no painel ou arrastado (NST-03-03).
    public func grantFile(_ url: URL) async throws(RSKeeperError) -> FileGrant {
        try await fileGrants.grant(forUserSelected: url)
    }

    // MARK: URL

    public func importURL(_ text: String, depositPasswordFor profileID: ProfileID) async throws(RSKeeperError) -> ImportedConnectionFields {
        let parsed: ParsedConnectionURL
        do {
            parsed = try ConnectionURLParser.parse(text)
        } catch {
            throw .validation(RedactedMessage(alreadyRedacted: Self.message(for: error)))
        }
        let driver: DriverID = switch parsed.kind {
        case .postgresql: .postgresql
        case .sqlite: .sqlite
        case .mysql: .mysql
        }
        guard drivers.factory(for: driver) != nil else {
            throw .unsupported(RedactedMessage(alreadyRedacted: "Este tipo de banco ainda não está disponível."))
        }
        if let password = parsed.password { await transient.deposit(password.reveal(), for: profileID) }
        return ImportedConnectionFields(driverID: driver, host: parsed.host, port: parsed.port, user: parsed.user,
                                        database: parsed.database, filePath: parsed.filePath, tlsMode: parsed.tlsMode,
                                        hasPassword: parsed.password != nil, ignoredParameters: parsed.ignoredParameters)
    }

    private static func message(for error: ConnectionURLError) -> String {
        switch error {
        case .invalidURL: "URL de conexão inválida."
        case .unsupportedScheme: "Esquema de URL não suportado."
        case .invalidPort: "Porta inválida na URL (1 a 65535)."
        case .invalidSSLMode: "sslmode desconhecido na URL."
        }
    }

    // MARK: Testar e conectar (NST-03-05)

    /// Abre e fecha uma conexão sem registrar sessão (F-CONN-02). Cancelável pela `Task`.
    public func test(_ profile: ConnectionProfile, password: String?) async throws(RSKeeperError) -> String {
        guard let factory = drivers.factory(for: profile.driverID) else {
            throw .unsupported(RedactedMessage(alreadyRedacted: "Driver não disponível."))
        }
        if let password, !password.isEmpty { await transient.deposit(password, for: profile.id) }
        let target = try await resolver.resolve(profile)
        if Task.isCancelled { throw .cancelled }
        do {
            let connection = try await factory.open(target, options: OpenOptions(readOnly: true, tls: profile.tls))
            let version = connection.serverVersion
            await connection.close()
            return version
        } catch {
            throw error.applicationError
        }
    }

    /// Conecta pela janela e registra o uso (F-CONN-07: o perfil vai para "recentes").
    public func recordUse(_ profile: ProfileID) async { try? await profiles.recordUse(profile) }

    public var connector: ConnectUseCase { connectUseCase }
}
