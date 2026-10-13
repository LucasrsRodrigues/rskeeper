import RSKeeperDomain

/// Referência a um schema (nil no MySQL/SQLite).
public struct SchemaRef: Hashable, Sendable {
    public let database: String?
    public let name: String?
    public init(database: String?, name: String?) {
        self.database = database
        self.name = name
    }
}

/// Referência a uma entidade, citada parte a parte pelo dialeto (AR-SQL-12).
public struct EntityRef: Hashable, Sendable {
    public let schema: SchemaRef
    public let name: String
    public init(schema: SchemaRef, name: String) {
        self.schema = schema
        self.name = name
    }
}

public struct DatabaseInfo: Hashable, Sendable {
    public let name: String
    public init(name: String) { self.name = name }
}

public struct SchemaInfo: Hashable, Sendable {
    public let ref: SchemaRef
    public init(ref: SchemaRef) { self.ref = ref }
}

public enum EntityKind: String, Hashable, Sendable { case table, view, materializedView, routine }

public struct EntityInfo: Hashable, Sendable {
    public let ref: EntityRef
    public let kind: EntityKind
    public init(ref: EntityRef, kind: EntityKind) {
        self.ref = ref
        self.kind = kind
    }
}

public struct ColumnInfo: Hashable, Sendable {
    public let name: String
    public let ordinal: Int
    public let declaredType: String
    public let portableType: PortableType
    public let nullable: Bool
    public let isPrimaryKey: Bool
    public init(name: String, ordinal: Int, declaredType: String, portableType: PortableType, nullable: Bool, isPrimaryKey: Bool) {
        self.name = name
        self.ordinal = ordinal
        self.declaredType = declaredType
        self.portableType = portableType
        self.nullable = nullable
        self.isPrimaryKey = isPrimaryKey
    }
}

/// Contagem de linhas: exata ou estimada.
public enum RowCount: Hashable, Sendable {
    case exact(Int)
    case estimate(Int)
}

/// Provedor de metadados (F-SCH-01/02). Detalhes (índices, chaves, DDL) entram com as histórias da onda 3.
public protocol MetadataProvider: Sendable {
    func databases() async throws(DriverError) -> [DatabaseInfo]
    func schemas(in database: String) async throws(DriverError) -> [SchemaInfo]
    func entities(in schema: SchemaRef) async throws(DriverError) -> [EntityInfo]
    func columns(of entity: EntityRef) async throws(DriverError) -> [ColumnInfo]
}

/// Estilo de placeholder do dialeto (DR-16).
public enum PlaceholderStyle: String, Hashable, Sendable { case question, dollarNumbered }

/// Dialeto SQL do driver (docs/native/04 §2.4).
public protocol Dialect: Sendable {
    var placeholderStyle: PlaceholderStyle { get }
    /// Cita um identificador duplicando o caractere de citação; rejeita NUL (AR-SQL-12).
    func quoteIdentifier(_ part: String) throws(DriverError) -> String
    func limitClause(limit: Int, offset: Int) -> String
}

extension Dialect {
    /// Nome qualificado: cada parte citada em separado, sem mudar caixa.
    public func qualified(_ ref: EntityRef) throws(DriverError) -> String {
        var parts: [String] = []
        if let database = ref.schema.database { parts.append(try quoteIdentifier(database)) }
        if let schema = ref.schema.name { parts.append(try quoteIdentifier(schema)) }
        parts.append(try quoteIdentifier(ref.name))
        return parts.joined(separator: ".")
    }
}

/// Dialeto padrão ANSI (aspas duplas, LIMIT/OFFSET). Usado pelo driver em memória e como base.
public struct ANSIDialect: Dialect {
    public let placeholderStyle: PlaceholderStyle
    public init(placeholderStyle: PlaceholderStyle = .question) { self.placeholderStyle = placeholderStyle }

    public func quoteIdentifier(_ part: String) throws(DriverError) -> String {
        guard !part.contains("\u{0}") else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador com NUL.")) }
        guard !part.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador vazio.")) }
        return "\"" + part.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func limitClause(limit: Int, offset: Int) -> String { "LIMIT \(limit) OFFSET \(offset)" }
}
