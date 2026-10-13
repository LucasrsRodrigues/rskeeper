import Foundation
import GRDB
import RSKeeperDomain

/// Pasta de conexões da sidebar.
public struct ProfileFolder: Hashable, Sendable, Identifiable {
    public var id: FolderID
    public var name: String
    public var parentID: FolderID?
    public var position: Int
    public var expanded: Bool

    public init(id: FolderID = .generate(), name: String, parentID: FolderID? = nil, position: Int = 0, expanded: Bool = true) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
        self.expanded = expanded
    }
}

/// Conteúdo da sidebar de conexões (NST-03-01): fixadas, salvas (com pastas) e recentes.
public struct ConnectionSidebarContent: Hashable, Sendable {
    public var pinned: [ConnectionProfile]
    public var saved: [ConnectionProfile]
    public var recent: [ConnectionProfile]
    public var folders: [ProfileFolder]

    public static let empty = ConnectionSidebarContent(pinned: [], saved: [], recent: [], folders: [])
}

/// Repositório de perfis, pastas e conexões fixadas (NST-02-03; porta DR-27).
///
/// - Toda atualização exige `expectedRevision`; divergência → `.conflict(.staleRevision)`.
/// - Mudanças chegam às outras janelas por observação (`sidebarUpdates`), sem recarga manual.
public struct ProfileRepository: Sendable {
    /// Recentes exibidos na sidebar [META].
    public static let recentLimit = 10

    private let database: AppDatabase

    public init(database: AppDatabase) { self.database = database }

    // MARK: Perfis

    public func insert(_ profile: ConnectionProfile) async throws(RSKeeperError) {
        try await write { db in try ProfileRow(profile).insert(db) }
    }

    /// Grava alterações se a revisão no banco ainda for `expectedRevision`; devolve o perfil com a
    /// revisão nova. A segunda janela que editou a mesma versão recebe `.conflict(.staleRevision)`.
    @discardableResult
    public func update(_ profile: ConnectionProfile, expectedRevision: Int) async throws(RSKeeperError) -> ConnectionProfile {
        var updated = profile
        updated.revision = expectedRevision + 1
        updated.updatedAt = Date()
        let row = ProfileRow(updated)
        try await write { db in
            let changed = try row.updateIfRevision(db, expected: expectedRevision)
            guard changed else {
                throw try ProfileRow.exists(db, profile.id) ? RSKeeperError.conflict(.staleRevision) : RSKeeperError.notFound(.unknown)
            }
        }
        return updated
    }

    public func delete(_ id: ProfileID, expectedRevision: Int) async throws(RSKeeperError) {
        try await write { db in
            try db.execute(sql: "DELETE FROM profile WHERE id = ? AND revision = ?", arguments: [id.raw, expectedRevision])
            guard db.changesCount == 1 else {
                throw try ProfileRow.exists(db, id) ? RSKeeperError.conflict(.staleRevision) : RSKeeperError.notFound(.unknown)
            }
        }
    }

    public func profile(_ id: ProfileID) async throws(RSKeeperError) -> ConnectionProfile {
        let found = try await read { db in try ProfileRow.fetchOne(db, sql: "SELECT * FROM profile WHERE id = ?", arguments: [id.raw]) }
        guard let found else { throw .notFound(.unknown) }
        return try found.profile()
    }

    public func allProfiles() async throws(RSKeeperError) -> [ConnectionProfile] {
        try await read { db in try ProfileRow.fetchAll(db, sql: "SELECT * FROM profile WHERE is_draft = 0 ORDER BY name COLLATE NOCASE") }
            .map { row throws(RSKeeperError) in try row.profile() }
    }

    /// [CONFIRMADO F-CONN-07] Ao abrir sessão o perfil passa a "recentes". Não mexe na revisão:
    /// usar a conexão não pode invalidar uma edição em curso em outra janela.
    public func recordUse(_ id: ProfileID, at date: Date = Date()) async throws(RSKeeperError) {
        try await write { db in
            try db.execute(sql: "UPDATE profile SET last_used_at = ? WHERE id = ?", arguments: [date, id.raw])
            guard db.changesCount == 1 else { throw RSKeeperError.notFound(.unknown) }
        }
    }

    /// Fixa no fim da lista de fixadas, ou desafixa. Organização da sidebar: não mexe na revisão.
    public func setPinned(_ id: ProfileID, _ pinned: Bool) async throws(RSKeeperError) {
        try await write { db in
            if pinned {
                try db.execute(sql: """
                    UPDATE profile SET pinned_position = (SELECT ifnull(max(pinned_position), -1) + 1 FROM profile)
                    WHERE id = ? AND pinned_position IS NULL
                    """, arguments: [id.raw])
            } else {
                try db.execute(sql: "UPDATE profile SET pinned_position = NULL WHERE id = ?", arguments: [id.raw])
            }
            guard try ProfileRow.exists(db, id) else { throw RSKeeperError.notFound(.unknown) }
        }
    }

    // MARK: Pastas

    public func insertFolder(_ folder: ProfileFolder) async throws(RSKeeperError) {
        try await write { db in
            try db.execute(sql: "INSERT INTO folder (id, name, parent_id, position, expanded, kind) VALUES (?, ?, ?, ?, ?, 'connection')",
                           arguments: [folder.id.raw, folder.name, folder.parentID?.raw, folder.position, folder.expanded])
        }
    }

    public func renameFolder(_ id: FolderID, to name: String) async throws(RSKeeperError) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw .validation(RedactedMessage(alreadyRedacted: "O nome da pasta não pode ser vazio."))
        }
        try await write { db in
            try db.execute(sql: "UPDATE folder SET name = ? WHERE id = ? AND kind = 'connection'", arguments: [name, id.raw])
            guard db.changesCount == 1 else { throw RSKeeperError.notFound(.unknown) }
        }
    }

    /// Exclui a pasta; os perfis dela voltam para a raiz (`ON DELETE SET NULL`), nunca são apagados.
    public func deleteFolder(_ id: FolderID) async throws(RSKeeperError) {
        try await write { db in
            try db.execute(sql: "DELETE FROM folder WHERE id = ? AND kind = 'connection'", arguments: [id.raw])
            guard db.changesCount == 1 else { throw RSKeeperError.notFound(.unknown) }
        }
    }

    // MARK: Sidebar e observação

    public func sidebar() async throws(RSKeeperError) -> ConnectionSidebarContent {
        try await read(Self.fetchSidebar)
    }

    /// Conteúdo da sidebar sempre que perfis ou pastas mudarem, em qualquer janela (aceite 4).
    /// Consumir num `Task` do MainActor para entregar à UI.
    public func sidebarUpdates() -> AsyncThrowingStream<ConnectionSidebarContent, any Error> {
        let observation = ValueObservation.tracking(Self.fetchSidebar).removeDuplicates()
        let values = observation.values(in: database.writer)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await value in values { continuation.yield(value) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @Sendable
    private static func fetchSidebar(_ db: Database) throws -> ConnectionSidebarContent {
        let rows = try ProfileRow.fetchAll(db, sql: "SELECT * FROM profile WHERE is_draft = 0")
        let profiles = try rows.map { row throws(RSKeeperError) in (row, try row.profile()) }
        let pinned = profiles.filter { $0.0.pinnedPosition != nil }.sorted { $0.0.pinnedPosition! < $1.0.pinnedPosition! }.map(\.1)
        let saved = profiles.map(\.1).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let recent = profiles.map(\.1).filter { $0.lastUsedAt != nil }
            .sorted { $0.lastUsedAt! > $1.lastUsedAt! }.prefix(recentLimit)
        let folders = try Row.fetchAll(db, sql: "SELECT * FROM folder WHERE kind = 'connection' ORDER BY position, name COLLATE NOCASE").map { row in
            ProfileFolder(id: FolderID(raw: row["id"]), name: row["name"], parentID: (row["parent_id"] as UUID?).map(FolderID.init(raw:)),
                          position: row["position"], expanded: row["expanded"])
        }
        return ConnectionSidebarContent(pinned: pinned, saved: saved, recent: Array(recent), folders: folders)
    }

    // MARK: Acesso com erro normalizado

    private func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws(RSKeeperError) -> T {
        do { return try await database.read(body) } catch { throw PersistenceErrors.map(error) }
    }

    private func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws(RSKeeperError) -> T {
        do { return try await database.write(body) } catch { throw PersistenceErrors.map(error) }
    }
}

enum PersistenceErrors {
    static func map(_ error: any Error) -> RSKeeperError {
        switch error {
        case let error as RSKeeperError: return error
        case PersistenceError.readOnlyDatabase: return .readOnly
        case let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE:
            return .validation(RedactedMessage(alreadyRedacted: "Já existe uma conexão com esse nome nesta pasta."))
        case let error as DatabaseError where error.resultCode == .SQLITE_CONSTRAINT:
            return .validation(RedactedMessage(alreadyRedacted: "Os dados violam uma regra do banco local."))
        default:
            return .internal(RedactedMessage(alreadyRedacted: "Falha no banco local."))
        }
    }
}

/// Linha da tabela `profile` ↔ `ConnectionProfile` (JSON para alvo, TLS, SSH e opções).
struct ProfileRow: FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "profile"

    var id: UUID
    var name: String
    var driverID: String
    var folderID: UUID?
    var labelColor: String
    var environment: String
    var environmentCustomID: UUID?
    var environmentConfirmed: Bool
    var readOnly: Bool
    var targetJSON: String
    var tlsJSON: String?
    var sshJSON: String?
    var defaultDatabase: String?
    var driverOptionsJSON: String
    var savePasswords: Bool
    var isDraft: Bool
    var revision: Int
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var pinnedPosition: Int?

    init(row: Row) throws {
        id = row["id"]; name = row["name"]; driverID = row["driver_id"]; folderID = row["folder_id"]
        labelColor = row["label_color"]; environment = row["environment"]; environmentCustomID = row["environment_custom_id"]
        environmentConfirmed = row["environment_confirmed"]; readOnly = row["read_only"]; targetJSON = row["target_json"]
        tlsJSON = row["tls_json"]; sshJSON = row["ssh_json"]; defaultDatabase = row["default_database"]
        driverOptionsJSON = row["driver_options_json"]; savePasswords = row["save_passwords"]; isDraft = row["is_draft"]
        revision = row["revision"]; createdAt = row["created_at"]; updatedAt = row["updated_at"]; lastUsedAt = row["last_used_at"]
        pinnedPosition = row["pinned_position"]
    }

    func encode(to container: inout PersistenceContainer) throws {
        container["id"] = id; container["name"] = name; container["driver_id"] = driverID; container["folder_id"] = folderID
        container["label_color"] = labelColor; container["environment"] = environment
        container["environment_custom_id"] = environmentCustomID; container["environment_confirmed"] = environmentConfirmed
        container["read_only"] = readOnly; container["target_json"] = targetJSON; container["tls_json"] = tlsJSON
        container["ssh_json"] = sshJSON; container["default_database"] = defaultDatabase
        container["driver_options_json"] = driverOptionsJSON; container["save_passwords"] = savePasswords
        container["is_draft"] = isDraft; container["revision"] = revision; container["created_at"] = createdAt
        container["updated_at"] = updatedAt; container["last_used_at"] = lastUsedAt
        // pinned_position é da organização da sidebar (setPinned); a edição do perfil não o altera.
    }

    init(_ profile: ConnectionProfile) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        func json<T: Encodable>(_ value: T) -> String { String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self) }
        id = profile.id.raw; name = profile.name; driverID = profile.driverID.rawValue; folderID = profile.folderID?.raw
        labelColor = profile.labelColor.rawValue
        (environment, environmentCustomID) = Self.environmentColumns(profile.environment)
        environmentConfirmed = profile.environmentConfirmed; readOnly = profile.readOnly
        targetJSON = json(profile.target); tlsJSON = profile.tls.map(json); sshJSON = profile.ssh.map(json)
        defaultDatabase = profile.defaultDatabase; driverOptionsJSON = json(profile.driverOptions)
        savePasswords = profile.savePasswords; isDraft = profile.isDraft; revision = profile.revision
        createdAt = profile.createdAt; updatedAt = profile.updatedAt; lastUsedAt = profile.lastUsedAt; pinnedPosition = nil
    }

    func profile() throws(RSKeeperError) -> ConnectionProfile {
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ text: String) throws(RSKeeperError) -> T {
            do { return try decoder.decode(type, from: Data(text.utf8)) } catch {
                throw .internal(RedactedMessage(alreadyRedacted: "Perfil salvo ilegível."))
            }
        }
        return ConnectionProfile(
            id: ProfileID(raw: id), name: name, driverID: DriverID(rawValue: driverID), folderID: folderID.map(FolderID.init(raw:)),
            labelColor: LabelColor(rawValue: labelColor) ?? .none, environment: try Self.environment(environment, environmentCustomID),
            environmentConfirmed: environmentConfirmed, readOnly: readOnly, target: try decode(ConnectionTarget.self, targetJSON),
            tls: try tlsJSON.map { text throws(RSKeeperError) in try decode(TLSOptions.self, text) },
            ssh: try sshJSON.map { text throws(RSKeeperError) in try decode(SSHOptions.self, text) },
            defaultDatabase: defaultDatabase, driverOptions: try decode([String: DriverOptionValue].self, driverOptionsJSON),
            savePasswords: savePasswords, isDraft: isDraft, revision: revision, createdAt: createdAt, updatedAt: updatedAt,
            lastUsedAt: lastUsedAt)
    }

    static func environmentColumns(_ kind: EnvironmentKind) -> (String, UUID?) {
        switch kind {
        case .local: ("local", nil)
        case .development: ("development", nil)
        case .testing: ("testing", nil)
        case .staging: ("staging", nil)
        case .production: ("production", nil)
        case .custom(let id): ("custom", id.raw)
        }
    }

    static func environment(_ name: String, _ customID: UUID?) throws(RSKeeperError) -> EnvironmentKind {
        switch name {
        case "local": return .local
        case "development": return .development
        case "testing": return .testing
        case "staging": return .staging
        case "production": return .production
        case "custom":
            guard let customID else { throw .internal(RedactedMessage(alreadyRedacted: "Ambiente personalizado sem identificador.")) }
            return .custom(EnvironmentID(raw: customID))
        default: throw .internal(RedactedMessage(alreadyRedacted: "Ambiente desconhecido no banco local."))
        }
    }

    /// `UPDATE … WHERE revision = esperado` (controle otimista atômico). Devolve se alterou a linha.
    func updateIfRevision(_ db: Database, expected: Int) throws -> Bool {
        try db.execute(sql: """
            UPDATE profile SET name = ?, driver_id = ?, folder_id = ?, label_color = ?, environment = ?,
                environment_custom_id = ?, environment_confirmed = ?, read_only = ?, target_json = ?, tls_json = ?,
                ssh_json = ?, default_database = ?, driver_options_json = ?, save_passwords = ?, is_draft = ?,
                revision = ?, updated_at = ?, last_used_at = ?
            WHERE id = ? AND revision = ?
            """, arguments: [name, driverID, folderID, labelColor, environment, environmentCustomID, environmentConfirmed,
                             readOnly, targetJSON, tlsJSON, sshJSON, defaultDatabase, driverOptionsJSON, savePasswords, isDraft,
                             revision, updatedAt, lastUsedAt, id, expected])
        return db.changesCount == 1
    }

    static func exists(_ db: Database, _ id: ProfileID) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM profile WHERE id = ?)", arguments: [id.raw]) ?? false
    }
}
