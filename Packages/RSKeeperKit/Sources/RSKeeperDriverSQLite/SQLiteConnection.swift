import Foundation
import GRDB
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperSQLKit
import SQLite3
import Synchronization

/// Conexão física com um arquivo SQLite do usuário.
public final class SQLiteConnection: PhysicalConnection {
    public let serverVersion: String
    private let queue: DatabaseQueue
    private let readOnly: Bool
    /// `-wal` não existia ao abrir: ao fechar, `PERSIST_WAL = 0` para não deixar arquivos (SPK-N05 F2).
    private let removeSidecarsOnClose: Bool
    private let closed = Mutex(false)

    private init(queue: DatabaseQueue, readOnly: Bool, removeSidecarsOnClose: Bool) {
        self.queue = queue
        self.readOnly = readOnly
        self.removeSidecarsOnClose = removeSidecarsOnClose
        self.serverVersion = "SQLite " + String(cString: sqlite3_libversion())
    }

    static func open(path: String, readOnly: Bool) throws(DriverError) -> SQLiteConnection {
        guard FileManager.default.fileExists(atPath: path) else {
            // Nunca cria arquivo: o driver abre o que o usuário escolheu (bookmark).
            throw .validation(RedactedMessage(alreadyRedacted: "Arquivo SQLite não encontrado."))
        }
        let sidecarsExisted = FileManager.default.fileExists(atPath: path + "-wal")
        do {
            return SQLiteConnection(queue: try DatabaseQueue(path: path, configuration: configuration(readOnly: readOnly, openReadOnly: readOnly)),
                                    readOnly: readOnly, removeSidecarsOnClose: !sidecarsExisted)
        } catch let error as DatabaseError where readOnly && error.resultCode == .SQLITE_CANTOPEN {
            // SPK-N05 F3b: arquivo em WAL sem `-wal`/`-shm` não abre com SQLITE_OPEN_READONLY.
            // Abre leitura-escrita com `query_only` e mantém a camada 3 (recusa no driver).
            do {
                return SQLiteConnection(queue: try DatabaseQueue(path: path, configuration: configuration(readOnly: true, openReadOnly: false)),
                                        readOnly: true, removeSidecarsOnClose: !sidecarsExisted)
            } catch {
                throw SQLiteErrors.map(error)
            }
        } catch {
            throw SQLiteErrors.map(error)
        }
    }

    private static func configuration(readOnly: Bool, openReadOnly: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.label = "rskeeper.sqlite"
        configuration.readonly = openReadOnly
        // O driver não muda o comportamento do arquivo: chaves estrangeiras como no padrão do SQLite (W1-D06).
        configuration.foreignKeysEnabled = false
        // A sessão decide o modo (Auto/Manual) e encerra transações abandonadas com resetSession (DR-17).
        configuration.allowsUnsafeTransactions = true
        configuration.busyMode = .timeout(0.5)
        if readOnly {
            configuration.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = 1") }
        }
        return configuration
    }

    // MARK: Execução

    public func stream(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int) -> ResultStream {
        let (stream, continuation) = ResultStream.makeStream()
        let task = Task { [self] in
            do {
                try await access { db in try self.run(statement, limits: limits, batchSize: batchSize, db: db, continuation: continuation) }
                continuation.finish()
            } catch {
                continuation.finish(throwing: SQLiteErrors.map(error))
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    /// Roda no executor serial do GRDB, nunca no MainActor.
    private func run(_ statement: BoundStatement, limits: ReadLimits, batchSize: Int, db: Database,
                     continuation: ResultStream.Continuation) throws {
        let prepared = try db.makeStatement(sql: statement.sql)
        if readOnly { try enforceReadOnly(statement.sql, prepared) }
        try prepared.setArguments(StatementArguments(statement.bindings.map(Self.databaseValue)))
        Self.rebindTextsWithNUL(statement.bindings, prepared.sqliteStatement)

        guard prepared.columnCount > 0 else {
            try prepared.execute()
            let tag = Self.commandTag(statement.sql)
            if ["INSERT", "UPDATE", "DELETE", "REPLACE"].contains(tag) {
                continuation.yield(.end(.affected(db.changesCount)))
            } else {
                continuation.yield(.end(.command(tag)))
            }
            return
        }

        let kinds = (0..<prepared.columnCount).map { index -> SQLiteColumnKind in
            SQLiteColumnKind(declaredType: sqlite3_column_decltype(prepared.sqliteStatement, Int32(index)).map { String(cString: $0) })
        }
        let columns = zip(prepared.columnNames, kinds).map {
            ResultColumn(name: $0, nativeTypeName: $1.declaredType, portableType: $1.portableType)
        }
        continuation.yield(.columns(columns))
        var accumulator = BatchAccumulator(columnCount: columns.count, limits: limits, batchSize: batchSize)
        let cursor = try Row.fetchCursor(prepared)
        let raw = prepared.sqliteStatement
        while let row = try cursor.next() {
            let values = (0..<columns.count).map { index -> CellValue in
                // Texto lido pelo comprimento em bytes: o caminho de string C cortaria em NUL (NT-DRV-04).
                if sqlite3_column_type(raw, Int32(index)) == SQLITE_TEXT, let text = sqlite3_column_text(raw, Int32(index)) {
                    let count = Int(sqlite3_column_bytes(raw, Int32(index)))
                    let string = String(decoding: UnsafeBufferPointer(start: text, count: count), as: UTF8.self)
                    return SQLiteValues.cell(string.databaseValue, kind: kinds[index], maxCellBytes: limits.maxCellBytes)
                }
                return SQLiteValues.cell(row[index] as DatabaseValue, kind: kinds[index], maxCellBytes: limits.maxCellBytes)
            }
            if accumulator.append(values) == .stop { break }        // para de ler: o cursor é descartado aqui
            if accumulator.readyBatch, let batch = accumulator.takeBatch() { continuation.yield(.batch(batch)) }
            if let deadline = limits.deadline, ContinuousClock.now >= deadline { throw DriverError.timedOut }
        }
        if let batch = accumulator.takeBatch() { continuation.yield(.batch(batch)) }
        continuation.yield(.end(accumulator.end))
    }

    /// Camada 3 do somente leitura (SPK-N05): `Statement.isReadonly` e classificação local
    /// (`ATTACH`, `PRAGMA query_only = 0`, `VACUUM INTO` não são barrados pelas outras camadas).
    private func enforceReadOnly(_ sql: String, _ prepared: Statement) throws {
        let classified = RiskClassifier.classify(sql, dialect: .sqlite)
        guard prepared.isReadonly, !classified.isEmpty, classified.allSatisfy({ $0.isAllowedInReadOnly }) else {
            throw DriverError.readOnly
        }
    }

    private static func commandTag(_ sql: String) -> String {
        let lexed = SQLLexer.tokenize(sql, dialect: .sqlite)
        return lexed.tokens.lazy.compactMap { lexed.keyword($0) }.first ?? "OK"
    }

    /// O GRDB liga `String` com comprimento -1 (para no primeiro NUL). Textos com NUL são ligados de
    /// novo com o comprimento em bytes, para chegar ao banco sem alteração (NT-DRV-04).
    private static func rebindTextsWithNUL(_ bindings: [BindValue], _ statement: OpaquePointer) {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)     // SQLITE_TRANSIENT
        for (index, binding) in bindings.enumerated() {
            guard case .text(let text) = binding, text.utf8.contains(0) else { continue }
            let bytes = Array(text.utf8)
            bytes.withUnsafeBufferPointer { buffer in
                buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                    _ = sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(bytes.count), transient)
                }
            }
        }
    }

    private static func databaseValue(_ value: BindValue) -> DatabaseValue {
        switch value {
        case .null: .null
        case .bool(let bool): bool.databaseValue
        case .int(let int): int.databaseValue
        case .double(let double): double.databaseValue
        case .text(let text), .decimalText(let text): text.databaseValue
        case .bytes(let bytes): Data(bytes).databaseValue
        }
    }

    // MARK: Estado, cancelamento e fechamento

    public func transactionState() async -> TransactionState {
        let inTransaction = try? await access { db in sqlite3_get_autocommit(db.sqliteConnection) == 0 }
        return inTransaction == true ? .inTransaction : .idle
    }

    /// DR-17: encerra uma transação abandonada (modo Auto) com ROLLBACK.
    public func resetSession() async throws(DriverError) {
        try await access { db in
            if sqlite3_get_autocommit(db.sqliteConnection) == 0 { try db.execute(sql: "ROLLBACK") }
        }
    }

    public func cancelHandle() -> (any CancelHandle)? { SQLiteCancelHandle(queue: queue) }

    public func close() async {
        let wasClosed = closed.withLock { value in
            defer { value = true }
            return value
        }
        guard !wasClosed else { return }
        if removeSidecarsOnClose {
            try? await queue.writeWithoutTransaction { db in
                var off: Int32 = 0
                _ = sqlite3_file_control(db.sqliteConnection, "main", SQLITE_FCNTL_PERSIST_WAL, &off)
            }
        }
        try? queue.close()
    }

    /// Acesso ao banco com erro normalizado; recusa conexão fechada.
    private func access<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws(DriverError) -> T {
        if closed.withLock({ $0 }) { throw .connection(RedactedMessage(alreadyRedacted: "Conexão fechada.")) }
        do {
            return try await queue.writeWithoutTransaction(body)
        } catch {
            throw SQLiteErrors.map(error)
        }
    }

    // MARK: Metadados (doc 04 §10)

    public func databases() async throws(DriverError) -> [DatabaseInfo] {
        [DatabaseInfo(name: "main")]
    }

    /// Schemas do SQLite: `main`, `temp` (se houver objetos) e bancos anexados.
    public func schemas(in database: String) async throws(DriverError) -> [SchemaInfo] {
        try await access { db in
            try String.fetchAll(db, sql: "SELECT name FROM pragma_database_list ORDER BY seq")
        }.map { SchemaInfo(ref: SchemaRef(database: nil, name: $0)) }
    }

    public func entities(in schema: SchemaRef) async throws(DriverError) -> [EntityInfo] {
        let name = schema.name ?? "main"
        let quoted = try SQLiteDialect().quoteIdentifier(name)
        let rows = try await access { db in
            try Row.fetchAll(db, sql: """
                SELECT name, type FROM \(quoted).sqlite_schema
                WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                ORDER BY name COLLATE NOCASE
                """).map { (row: Row) -> (String, String) in (row["name"], row["type"]) }
        }
        return rows.map { EntityInfo(ref: EntityRef(schema: SchemaRef(database: nil, name: name), name: $0.0),
                                     kind: $0.1 == "view" ? .view : .table) }
    }

    public func columns(of entity: EntityRef) async throws(DriverError) -> [DriverColumnInfo] {
        let schema = entity.schema.name ?? "main"
        let table = entity.name
        let rows = try await access { db in
            try Row.fetchAll(db, sql: "SELECT cid, name, type, \"notnull\", pk, hidden FROM pragma_table_xinfo(?, ?)",
                             arguments: [table, schema])
                .filter { ($0["hidden"] as Int) != 1 }
                .map { (row: Row) -> (Int, String, String, Bool, Bool) in
                    (row["cid"], row["name"], row["type"], (row["notnull"] as Int) != 0, (row["pk"] as Int) > 0)
                }
        }
        guard !rows.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Tabela ou view inexistente.")) }
        return rows.map { cid, name, type, notNull, primaryKey in
            DriverColumnInfo(name: name, ordinal: cid + 1, declaredType: type,
                       portableType: SQLiteColumnKind(declaredType: type).portableType,
                       nullable: !notNull && !primaryKey, isPrimaryKey: primaryKey)
        }
    }
}

/// `sqlite3_interrupt`: interrompe o passo nativo em curso; a conexão continua utilizável (DR-29).
struct SQLiteCancelHandle: CancelHandle {
    let queue: DatabaseQueue
    func cancel() async { queue.interrupt() }
}
