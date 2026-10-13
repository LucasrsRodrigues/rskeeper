import Foundation
import RSKeeperDomain
import RSKeeperDriversCore

/// Driver SQLite (NST-04-02; ADR-N16, ADR-N21; regras do SPK-N05).
///
/// - Arquivos do usuário só com `DatabaseQueue` (o `DatabasePool` converteria o arquivo para WAL).
/// - Nunca executa `PRAGMA journal_mode`; não deixa `-wal`/`-shm` que não existiam.
/// - Somente leitura em 3 camadas: `SQLITE_OPEN_READONLY`, `PRAGMA query_only` e recusa no driver
///   de instruções que não sejam leitura.
/// - Cancelamento por `sqlite3_interrupt` (`CancelMode.interrupt`).
public struct SQLiteDriver: DriverFactory {
    public let descriptor = DriverDescriptor(
        id: .sqlite, displayName: "SQLite", targetKind: .file,
        capabilities: DriverCapabilities(
            cancel: .interrupt, transactions: true, savepoints: true, transactionalDDL: true,
            schemas: true, changeDatabaseInSession: false, ilike: false, returning: true,
            streaming: .cursor, readOnly: .connectionOpen, tls: false, ssh: false,
            statementTimeout: .clientDeadlineOnly, materializedViews: false, routines: false,
            triggers: true, partitions: false, explain: true, explainAnalyze: false, health: false,
            introspection: .basic),
        dialect: SQLiteDialect())

    public init() {}

    public func validate(_ target: ConnectionTarget) throws(DriverError) {
        guard target.kind == .file else {
            throw .validation(RedactedMessage(alreadyRedacted: "O SQLite abre um arquivo, não um servidor."))
        }
    }

    public func open(_ target: ResolvedTarget, options: OpenOptions) async throws(DriverError) -> any PhysicalConnection {
        guard case .file(let path, let readOnly) = target else {
            throw .validation(RedactedMessage(alreadyRedacted: "O SQLite abre um arquivo, não um servidor."))
        }
        return try SQLiteConnection.open(path: path, readOnly: readOnly || options.readOnly)
    }
}

/// Dialeto do SQLite: identificadores entre aspas duplas, placeholders `?`, `LIMIT … OFFSET`.
public struct SQLiteDialect: Dialect {
    public init() {}
    public var placeholderStyle: PlaceholderStyle { .question }

    public func quoteIdentifier(_ part: String) throws(DriverError) -> String {
        guard !part.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador vazio.")) }
        guard !part.contains("\u{0}") else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador com NUL.")) }
        return "\"" + part.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func limitClause(limit: Int, offset: Int) -> String { "LIMIT \(limit) OFFSET \(offset)" }
}

/// `ColumnInfo` do RSKeeper (o GRDB tem um tipo de mesmo nome; este arquivo não importa o GRDB).
public typealias DriverColumnInfo = ColumnInfo
