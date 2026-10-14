import RSKeeperDomain
import RSKeeperDriversCore

/// Tipo de entidade do explorador (CAP-04B: ícone por tipo).
public enum ExplorerEntityKind: String, Sendable, Hashable { case table, view, materializedView, routine }

public struct ExplorerEntity: Hashable, Sendable, Identifiable {
    public let database: String?
    public let schema: String?
    public let name: String
    public let kind: ExplorerEntityKind
    public var id: String { [database ?? "", schema ?? "", name, kind.rawValue].joined(separator: "\u{1F}") }
    /// Aba de tabela correspondente (NST-08-02).
    public var tabKind: TabKind { .table(database: database, schema: schema, name: name) }
}

public struct ExplorerColumn: Hashable, Sendable, Identifiable {
    public let name: String
    public let declaredType: String
    public let isPrimaryKey: Bool
    public let nullable: Bool
    public var id: String { name }
}

/// Metadados para o explorador (NST-05-02), sem expor o protocolo de driver à UI.
/// Cache por (database, schema), invalidado em `refresh()` e depois de DDL.
public actor ExplorerService {
    private let session: DatabaseSession
    private var schemaCache: [String: [String]] = [:]
    private var entityCache: [String: [ExplorerEntity]] = [:]
    private var columnCache: [String: [ExplorerColumn]] = [:]

    public init(session: DatabaseSession) { self.session = session }

    /// Database da conexão (sem troca de database na sessão na onda 1: o seletor mostra só este).
    public func currentDatabase() async throws(RSKeeperError) -> String {
        let current: String? = try await session.withMetadata { provider throws(DriverError) in
            guard let connection = provider as? any PhysicalConnection,
                  case .rows(_, let batch, _, _)? = try? await connection.execute(BoundStatement(sql: "SELECT current_database()"), limits: .default),
                  case .text(let name)? = batch.columns.first?.first else { return nil }
            return name
        }
        if let current { return current }
        return try await databases().first ?? "main"
    }

    public func databases() async throws(RSKeeperError) -> [String] {
        try await session.withMetadata { provider throws(DriverError) in try await provider.databases().map(\.name) }
    }

    public func schemas(in database: String) async throws(RSKeeperError) -> [String] {
        if let cached = schemaCache[database] { return cached }
        let names = try await session.withMetadata { provider throws(DriverError) in
            try await provider.schemas(in: database).compactMap(\.ref.name)
        }
        schemaCache[database] = names
        return names
    }

    public func entities(database: String?, schema: String?) async throws(RSKeeperError) -> [ExplorerEntity] {
        let key = "\(database ?? "")\u{1F}\(schema ?? "")"
        if let cached = entityCache[key] { return cached }
        let found = try await session.withMetadata { provider throws(DriverError) in
            try await provider.entities(in: SchemaRef(database: database, name: schema))
        }
        let items = found.map { info in
            let kind: ExplorerEntityKind = switch info.kind {
            case .table: .table
            case .view: .view
            case .materializedView: .materializedView
            case .routine: .routine
            }
            return ExplorerEntity(database: database, schema: schema, name: info.ref.name, kind: kind)
        }
        entityCache[key] = items
        return items
    }

    public func columns(of entity: ExplorerEntity) async throws(RSKeeperError) -> [ExplorerColumn] {
        if let cached = columnCache[entity.id] { return cached }
        let ref = EntityRef(schema: SchemaRef(database: entity.database, name: entity.schema), name: entity.name)
        let found = try await session.withMetadata { provider throws(DriverError) in try await provider.columns(of: ref) }
        let items = found.sorted { $0.ordinal < $1.ordinal }.map {
            ExplorerColumn(name: $0.name, declaredType: $0.declaredType, isPrimaryKey: $0.isPrimaryKey, nullable: $0.nullable)
        }
        columnCache[entity.id] = items
        return items
    }

    /// "Atualizar" (⌘R) e depois de DDL: esquece tudo; a próxima leitura vai ao banco.
    public func refresh() {
        schemaCache.removeAll()
        entityCache.removeAll()
        columnCache.removeAll()
    }
}
