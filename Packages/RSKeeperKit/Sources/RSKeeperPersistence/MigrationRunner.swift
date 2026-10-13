import Foundation
import GRDB
import RSKeeperSecurity

/// Abre o banco local e aplica migrações com segurança (W0-T23; docs/native/05 §5; lição U-22).
///
/// Ordem: abrir → detectar migrações desconhecidas (banco mais novo → só leitura) → se houver
/// migrações pendentes num banco com dados, **backup** (VACUUM INTO, 5 retidos) → migrar, cada
/// migração em transação → em falha, rollback + backup preservado + modo de recuperação.
public struct MigrationRunner: Sendable {
    public let root: DataRoot
    public let migrations: [Migration]
    public let appVersion: String

    public init(root: DataRoot, migrations: [Migration] = MigrationCatalog.standard, appVersion: String) {
        self.root = root
        self.migrations = migrations
        self.appVersion = appVersion
    }

    /// Abre o banco. Corrupção resulta em `PersistenceError.corrupted` (a restauração exige consentimento).
    public func open() async throws -> AppDatabase {
        try root.prepare()
        let path = root.databaseFile.path
        let existed = FileManager.default.fileExists(atPath: path)

        let pool: DatabasePool
        do {
            pool = try DatabasePool(path: path, configuration: Self.configuration(readOnly: false))
            if existed { try await pool.read { db in _ = try Int.fetchOne(db, sql: "SELECT count(*) FROM sqlite_master") } }
        } catch let error as DatabaseError where Self.isCorruption(error) {
            throw PersistenceError.corrupted
        }

        let applied = try await Self.applied(pool)
        let known = Set(migrations.map(\.identifier))
        let unknown = applied.filter { !known.contains($0) }
        if !unknown.isEmpty {
            try pool.close()
            let readOnly = try DatabasePool(path: path, configuration: Self.configuration(readOnly: true))
            return AppDatabase(writer: readOnly, mode: .readOnlyNewerSchema(unknownMigrations: unknown))
        }

        let pending = migrations.filter { !applied.contains($0.identifier) }
        guard !pending.isEmpty else { return AppDatabase(writer: pool, mode: .readWrite) }

        var backup: URL?
        if existed, !applied.isEmpty {
            backup = try BackupManager(root: root).backup(pool, appVersion: appVersion)
        }

        var migrator = DatabaseMigrator()
        for migration in migrations {
            let body = migration.body
            migrator.registerMigration(migration.identifier) { db in try body(db) }
        }
        do {
            try migrator.migrate(pool)
        } catch {
            let failed = try await Self.firstPendingAfter(pool, migrations: migrations)
            try pool.close()
            let readOnly = try DatabasePool(path: path, configuration: Self.configuration(readOnly: true))
            return AppDatabase(writer: readOnly, mode: .recovery(failedMigration: failed, backup: backup))
        }
        return AppDatabase(writer: pool, mode: .readWrite)
    }

    static func configuration(readOnly: Bool) -> Configuration {
        var configuration = Configuration()
        configuration.readonly = readOnly
        configuration.foreignKeysEnabled = true
        configuration.label = "RSKeeper.AppDatabase"
        return configuration
    }

    static func applied(_ pool: DatabasePool) async throws -> [String] {
        try await pool.read { db in
            guard try db.tableExists("grdb_migrations") else { return [] }
            return try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations ORDER BY rowid")
        }
    }

    static func firstPendingAfter(_ pool: DatabasePool, migrations: [Migration]) async throws -> String {
        let applied = try await applied(pool)
        return migrations.first { !applied.contains($0.identifier) }?.identifier ?? "?"
    }

    static func isCorruption(_ error: DatabaseError) -> Bool {
        error.resultCode == .SQLITE_NOTADB || error.resultCode == .SQLITE_CORRUPT
    }
}
