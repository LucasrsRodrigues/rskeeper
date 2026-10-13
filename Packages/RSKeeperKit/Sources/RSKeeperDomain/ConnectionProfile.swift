import Foundation

/// Identificador de driver (`"sqlite"`, `"postgresql"`, `"mysql"`).
public struct DriverID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let sqlite = DriverID(rawValue: "sqlite")
    public static let postgresql = DriverID(rawValue: "postgresql")
    public static let mysql = DriverID(rawValue: "mysql")
}

/// Tipo de alvo exigido por um driver.
public enum TargetKind: String, Hashable, Sendable, Codable { case file, server }

/// Cor de rótulo da conexão (8 opções; nomes e valores próprios — docs/native/07 §2.5).
public enum LabelColor: String, Hashable, Sendable, Codable, CaseIterable {
    case none, slate, teal, blue, violet, green, amber, red
}

/// Concessão persistente de acesso a arquivo (bookmark), nunca caminho cru (porta DR-02).
public struct FileGrant: Hashable, Sendable, Codable {
    public let id: UUID
    /// Caminho só para exibição; nunca usado para abrir o arquivo.
    public let displayPath: String

    public init(id: UUID, displayPath: String) {
        self.id = id
        self.displayPath = displayPath
    }
}

public enum FileOpenMode: String, Hashable, Sendable, Codable { case readWrite, readOnly }

/// Finalidade de um segredo guardado no Keychain.
public enum SecretPurpose: String, Hashable, Sendable, Codable, CaseIterable {
    case password, sshPassword, sshKeyPassphrase, tlsKeyPassphrase
}

/// Chave de um segredo no Keychain: perfil + finalidade.
public struct SecretKey: Hashable, Sendable, Codable {
    public let profileID: ProfileID
    public let purpose: SecretPurpose
    public init(profileID: ProfileID, purpose: SecretPurpose) {
        self.profileID = profileID
        self.purpose = purpose
    }
}

/// Impressão digital do alvo (SHA-256 de driver|host|porta|usuário|destino SSH), calculada em
/// RSKeeperSecurity. O domínio só compara (porta DR-01).
public struct TargetFingerprint: Hashable, Sendable, Codable {
    public let digest: [UInt8]
    public init(digest: [UInt8]) { self.digest = digest }
}

/// Referência a um segredo. O perfil nunca guarda o valor (03 §2.2).
public enum SecretRef: Hashable, Sendable, Codable {
    case stored(SecretKey, fingerprint: TargetFingerprint)
    case prompt
    case missing
}

public enum TLSVersion: String, Hashable, Sendable, Codable { case v1_2, v1_3 }

public struct TLSOptions: Hashable, Sendable, Codable {
    public enum Mode: String, Hashable, Sendable, Codable { case disable, prefer, require, verifyCA, verifyFull }
    public var mode: Mode
    public var caFile: FileGrant?
    public var clientCertificate: FileGrant?
    public var clientKey: FileGrant?
    public var keyPassphrase: SecretRef?
    public var minimumVersion: TLSVersion

    public init(mode: Mode, caFile: FileGrant? = nil, clientCertificate: FileGrant? = nil, clientKey: FileGrant? = nil,
                keyPassphrase: SecretRef? = nil, minimumVersion: TLSVersion = .v1_2) {
        self.mode = mode
        self.caFile = caFile
        self.clientCertificate = clientCertificate
        self.clientKey = clientKey
        self.keyPassphrase = keyPassphrase
        self.minimumVersion = minimumVersion
    }
}

public enum HostKeyPolicy: String, Hashable, Sendable, Codable { case strict, trustOnFirstUseWithConfirmation }

public struct SSHOptions: Hashable, Sendable, Codable {
    public enum Auth: Hashable, Sendable, Codable {
        case password(SecretRef?)
        case privateKey(FileGrant, passphrase: SecretRef?)
        case agent
    }
    public var host: String
    public var port: UInt16
    public var user: String
    public var auth: Auth
    public var hostKeyPolicy: HostKeyPolicy
    public var keepAliveSeconds: Int

    public init(host: String, port: UInt16 = 22, user: String, auth: Auth,
                hostKeyPolicy: HostKeyPolicy = .trustOnFirstUseWithConfirmation, keepAliveSeconds: Int = 30) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.hostKeyPolicy = hostKeyPolicy
        self.keepAliveSeconds = keepAliveSeconds
    }
}

/// Alvo da conexão.
public enum ConnectionTarget: Hashable, Sendable, Codable {
    case file(FileGrant, openMode: FileOpenMode)
    case server(host: String, port: UInt16, user: String?, password: SecretRef?)

    public var kind: TargetKind {
        switch self {
        case .file: .file
        case .server: .server
        }
    }
}

/// Valor de opção específica de driver.
public enum DriverOptionValue: Hashable, Sendable, Codable {
    case string(String), int(Int), bool(Bool)
}

/// O que o perfil precisa saber do driver para validar invariantes (03 §2.1, inv. 1–2).
public struct DriverRequirements: Hashable, Sendable {
    public let targetKind: TargetKind
    public let supportsTLS: Bool
    public let supportsSSH: Bool
    public init(targetKind: TargetKind, supportsTLS: Bool, supportsSSH: Bool) {
        self.targetKind = targetKind
        self.supportsTLS = supportsTLS
        self.supportsSSH = supportsSSH
    }
}

/// Violação de invariante do perfil.
public enum ProfileValidationError: Error, Hashable, Sendable {
    case emptyName
    case targetKindMismatch(expected: TargetKind, actual: TargetKind)
    case tlsNotSupported
    case sshNotSupported
    case sshRequiresServerTarget
    case invalidPort
    case storedSecretWithoutSavePasswords
}

/// Perfil de conexão salvo ou rascunho (docs/native/03 §2.1).
public struct ConnectionProfile: Hashable, Sendable, Identifiable, Codable {
    public var id: ProfileID
    public var name: String
    public var driverID: DriverID
    public var folderID: FolderID?
    public var labelColor: LabelColor
    public var environment: EnvironmentKind
    public var environmentConfirmed: Bool
    public var readOnly: Bool
    public var target: ConnectionTarget
    public var tls: TLSOptions?
    public var ssh: SSHOptions?
    public var defaultDatabase: String?
    public var driverOptions: [String: DriverOptionValue]
    public var savePasswords: Bool
    public var isDraft: Bool
    public var revision: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var lastUsedAt: Date?

    public init(id: ProfileID = .generate(), name: String, driverID: DriverID, folderID: FolderID? = nil,
                labelColor: LabelColor = .none, environment: EnvironmentKind? = nil, environmentConfirmed: Bool = false,
                readOnly: Bool = false, target: ConnectionTarget, tls: TLSOptions? = nil, ssh: SSHOptions? = nil,
                defaultDatabase: String? = nil, driverOptions: [String: DriverOptionValue] = [:],
                savePasswords: Bool = true, isDraft: Bool = false, revision: Int = 0,
                createdAt: Date = Date(), updatedAt: Date? = nil, lastUsedAt: Date? = nil) {
        self.id = id
        self.name = name
        self.driverID = driverID
        self.folderID = folderID
        self.labelColor = labelColor
        self.environment = environment ?? EnvironmentKind.suggested(for: target)
        self.environmentConfirmed = environmentConfirmed
        self.readOnly = readOnly
        self.target = target
        self.tls = tls
        self.ssh = ssh
        self.defaultDatabase = defaultDatabase
        self.driverOptions = driverOptions
        self.savePasswords = savePasswords
        self.isDraft = isDraft
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.lastUsedAt = lastUsedAt
    }

    /// Valida as invariantes 1, 2, 3, 5 e 6 de docs/native/03 §2.1.
    public func validate(against driver: DriverRequirements) throws(ProfileValidationError) {
        if !isDraft, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw .emptyName }
        if target.kind != driver.targetKind { throw .targetKindMismatch(expected: driver.targetKind, actual: target.kind) }
        if tls != nil, !driver.supportsTLS { throw .tlsNotSupported }
        if ssh != nil {
            guard driver.supportsSSH else { throw .sshNotSupported }
            guard target.kind == .server else { throw .sshRequiresServerTarget }
        }
        if case .server(_, let port, _, _) = target, port == 0 { throw .invalidPort }
        if let ssh, ssh.port == 0 { throw .invalidPort }
        if !savePasswords, allSecretRefs.contains(where: { if case .stored = $0 { true } else { false } }) {
            throw .storedSecretWithoutSavePasswords
        }
    }

    /// Todos os `SecretRef` do perfil.
    public var allSecretRefs: [SecretRef] {
        var refs: [SecretRef] = []
        if case .server(_, _, _, let password?) = target { refs.append(password) }
        if let passphrase = tls?.keyPassphrase { refs.append(passphrase) }
        switch ssh?.auth {
        case .password(let ref?): refs.append(ref)
        case .privateKey(_, let passphrase?): refs.append(passphrase)
        default: break
        }
        return refs
    }

    /// Invariante 7 (porta DR-01, AR-IPC-01): ao salvar com outra impressão de alvo sem um novo segredo,
    /// todo `SecretRef.stored` gravado para a impressão antiga vira `.missing`.
    public func invalidatingSecrets(notMatching current: TargetFingerprint) -> ConnectionProfile {
        func check(_ ref: SecretRef?) -> SecretRef? {
            guard let ref else { return nil }
            if case .stored(_, let fingerprint) = ref, fingerprint != current { return .missing }
            return ref
        }
        var copy = self
        if case .server(let host, let port, let user, let password) = target {
            copy.target = .server(host: host, port: port, user: user, password: check(password))
        }
        copy.tls?.keyPassphrase = check(tls?.keyPassphrase)
        if let auth = ssh?.auth {
            switch auth {
            case .password(let ref): copy.ssh?.auth = .password(check(ref))
            case .privateKey(let grant, let passphrase): copy.ssh?.auth = .privateKey(grant, passphrase: check(passphrase))
            case .agent: break
            }
        }
        return copy
    }

    /// Normaliza o nome para a comparação de unicidade por pasta (invariante 6: sem distinguir maiúsculas).
    public var uniquenessKey: String { name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}
