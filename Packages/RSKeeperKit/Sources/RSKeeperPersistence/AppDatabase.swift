import Foundation
import GRDB
import RSKeeperSecurity

/// Banco local do app (W0-T22; ADR-N05): `DatabasePool` em WAL dentro da raiz de dados.
///
/// Só tem API assíncrona: nenhum acesso síncrono a partir do MainActor (aceite 3).
public final class AppDatabase: Sendable {
    /// Estado de abertura.
    public enum Mode: Equatable, Sendable {
        /// Normal: leitura e escrita.
        case readWrite
        /// O banco foi criado por uma versão mais nova (migrações desconhecidas): só leitura (NT-MIG-06).
        case readOnlyNewerSchema(unknownMigrations: [String])
        /// Uma migração falhou: transação desfeita, backup preservado, só leitura (NT-MIG-04).
        case recovery(failedMigration: String, backup: URL?)
    }

    public let mode: Mode
    let writer: DatabasePool

    init(writer: DatabasePool, mode: Mode) {
        self.writer = writer
        self.mode = mode
    }

    public var isReadOnly: Bool { mode != .readWrite }

    /// Leitura assíncrona.
    public func read<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(body)
    }

    /// Escrita assíncrona transacional. Falha em modo somente leitura.
    public func write<T: Sendable>(_ body: @escaping @Sendable (Database) throws -> T) async throws -> T {
        guard !isReadOnly else { throw PersistenceError.readOnlyDatabase }
        return try await writer.write(body)
    }

    /// Identificadores de migração aplicados.
    public func appliedMigrations() async throws -> [String] {
        try await writer.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    /// Caminho do arquivo do banco (para diagnóstico de testes; nunca exibido ao usuário).
    public var path: String { writer.path }
}
