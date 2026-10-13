import CryptoKit
import Foundation
import GRDB
import Testing
@testable import RSKeeperPersistence
import RSKeeperSecurity

/// Raiz temporária isolada por teste, com um diretório-sentinela FORA da raiz (NT-MIG-05).
private struct Sandbox {
    let base: URL
    let root: DataRoot
    let sentinel: URL

    init() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rsk-mig-\(UUID().uuidString)")
        root = DataRoot(url: base.appendingPathComponent("root"))
        sentinel = base.appendingPathComponent("sentinela")
        try FileManager.default.createDirectory(at: sentinel, withIntermediateDirectories: true)
        try Data("não tocar".utf8).write(to: sentinel.appendingPathComponent("main.log"))
        try Data("antigo".utf8).write(to: sentinel.appendingPathComponent("main.old.log"))
    }

    /// Hash e mtime de tudo fora da raiz (sentinela).
    func sentinelFingerprint() throws -> [String: String] {
        var result: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: sentinel.path).sorted() {
            let url = sentinel.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            let mtime = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            result[name] = SHA256.hash(data: data).description + "|\(mtime?.timeIntervalSince1970 ?? 0)"
        }
        return result
    }

    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

/// Esquema esperado da v1 (snapshot em código): tabela → colunas.
private let expectedV1Schema: [String: [String]] = [
    "folder": ["id", "name", "parent_id", "position", "expanded", "kind"],
    "profile": ["id", "name", "driver_id", "folder_id", "label_color", "environment", "environment_custom_id",
                "environment_confirmed", "read_only", "target_json", "tls_json", "ssh_json", "default_database",
                "driver_options_json", "save_passwords", "is_draft", "revision", "created_at", "updated_at", "last_used_at"],
    "secret_ref": ["profile_id", "purpose", "fingerprint", "state"],
    "file_grant": ["id", "profile_id", "purpose", "bookmark", "display_path", "read_only", "created_at"],
    "pin": ["profile_id", "entity_json", "kind", "position"],
    "hidden": ["profile_id", "entity_json", "kind", "position"],
    "saved_query": ["id", "name", "text", "folder_id", "profile_id", "revision", "created_at", "updated_at"],
    "history": ["execution_id", "profile_id", "text", "reports_json", "outcome", "started_at", "duration_ms"],
    "tab": ["id", "profile_id", "owner_window", "kind_json", "title", "title_scope", "position", "is_dirty", "updated_at"],
    "closed_tab": ["id", "profile_id", "kind_json", "closed_at"],
    "draft": ["id", "tab_id", "profile_id", "text", "saved_text_hash", "updated_at"],
    "grid_layout": ["profile_id", "entity_json", "layout_json"],
    "preference": ["key", "value_json"],
    "workspace_layout": ["profile_id", "window_key", "layout_json"],
    "shortcut_override": ["command_id", "key_equivalent", "modifiers"],
    "known_host": ["host", "port", "key_type", "fingerprint_sha256", "added_at"],
    "job_log": ["job_id", "kind", "state", "partial_path", "started_at", "finished_at", "summary_json"],
]

@Suite("Migrações do banco local (NT-MIG-01, 03…07)", .serialized)
struct MigrationTests {
    @Test("NT-MIG-01: banco vazio → todas as migrações → esquema igual ao snapshot; WAL na raiz")
    func emptyToCurrentMatchesSnapshot() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let database = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        #expect(database.mode == .readWrite)
        #expect(try await database.appliedMigrations() == ["v1_initial"])
        #expect(database.path == box.root.databaseFile.path)
        let schema = try await database.read { db -> [String: [String]] in
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                AND name NOT LIKE 'sqlite_%' AND name != 'grdb_migrations'
                """)
            var result: [String: [String]] = [:]
            for table in tables { result[table] = try db.columns(in: table).map(\.name) }
            return result
        }
        #expect(schema == expectedV1Schema)
        let journal = try await database.read { db in try String.fetchOne(db, sql: "PRAGMA journal_mode") }
        #expect(journal == "wal")
        #expect(try BackupManager(root: box.root).backups().isEmpty, "banco novo não precisa de backup")
    }

    @Test("NT-MIG-03: rodar o migrador duas vezes não altera nada")
    func idempotent() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let first = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        let before = try await first.read { db in try String?.fetchAll(db, sql: "SELECT sql FROM sqlite_master ORDER BY name") }
        let second = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        let after = try await second.read { db in try String?.fetchAll(db, sql: "SELECT sql FROM sqlite_master ORDER BY name") }
        #expect(before == after)
        #expect(try await second.appliedMigrations() == ["v1_initial"])
        #expect(try BackupManager(root: box.root).backups().isEmpty, "sem migração pendente, sem backup")
    }

    @Test("NT-MIG-04: falha injetada → rollback, backup preservado e modo de recuperação")
    func injectedFailureRollsBack() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v1 = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        try await v1.write { db in try db.execute(sql: "INSERT INTO preference(key, value_json) VALUES ('k', '1')") }
        let failing = MigrationCatalog.standard + [
            Migration(identifier: "v2_falha") { db in
                try db.execute(sql: "CREATE TABLE parcial(x)")
                try db.execute(sql: "ISTO NÃO É SQL")
            },
        ]
        let database = try await MigrationRunner(root: box.root, migrations: failing, appVersion: "0.0.2").open()
        guard case .recovery(let failed, let backup?) = database.mode else { Issue.record("modo: \(database.mode)"); return }
        #expect(failed == "v2_falha")
        #expect(FileManager.default.fileExists(atPath: backup.path))
        #expect(try await database.appliedMigrations() == ["v1_initial"])
        let partialExists = try await database.read { db in try db.tableExists("parcial") }
        #expect(!partialExists, "a migração que falhou foi desfeita inteira")
        await #expect(throws: PersistenceError.readOnlyDatabase) { try await database.write { _ in () } }
        // O backup contém os dados de antes da migração.
        let restoredValue = try await DatabaseQueue(path: backup.path).read { db in
            try String.fetchOne(db, sql: "SELECT value_json FROM preference WHERE key = 'k'")
        }
        #expect(restoredValue == "1")
    }

    @Test("NT-MIG-05: nenhuma escrita, truncamento ou remoção fora da raiz (lição U-22)")
    func noEffectsOutsideRoot() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let before = try box.sentinelFingerprint()
        _ = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        let v2 = MigrationCatalog.standard + [Migration(identifier: "v2_teste") { db in try db.execute(sql: "CREATE TABLE t2(x)") }]
        _ = try await MigrationRunner(root: box.root, migrations: v2, appVersion: "0.0.2").open()
        #expect(try box.sentinelFingerprint() == before)
        let outside = try FileManager.default.contentsOfDirectory(atPath: box.base.path).sorted()
        #expect(outside == ["root", "sentinela"], "nada criado fora da raiz: \(outside)")
    }

    @Test("NT-MIG-06: banco de versão mais nova abre só leitura")
    func newerDatabaseOpensReadOnly() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let newer = MigrationCatalog.standard + [Migration(identifier: "v9_futuro") { db in try db.execute(sql: "CREATE TABLE futuro(x)") }]
        _ = try await MigrationRunner(root: box.root, migrations: newer, appVersion: "9.0").open()
        let database = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        #expect(database.mode == .readOnlyNewerSchema(unknownMigrations: ["v9_futuro"]))
        await #expect(throws: PersistenceError.readOnlyDatabase) { try await database.write { _ in () } }
        #expect(try await database.read { db in try db.tableExists("futuro") })
    }

    @Test("NT-MIG-07: banco corrompido → erro; restauração só com consentimento")
    func corruptedDatabaseRestoresWithConsent() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let v1 = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        try await v1.write { db in try db.execute(sql: "INSERT INTO preference(key, value_json) VALUES ('k', '42')") }
        try BackupManager(root: box.root).backup(v1.writer, appVersion: "0.0.1")
        try v1.writer.close()
        try Data(repeating: 0xAB, count: 8_192).write(to: box.root.databaseFile)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: box.root.databaseFile.path + suffix) }

        await #expect(throws: PersistenceError.corrupted) { _ = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open() }
        #expect(throws: PersistenceError.consentRequired) { _ = try BackupManager(root: box.root).restoreLatestBackup(consent: false) }
        _ = try BackupManager(root: box.root).restoreLatestBackup(consent: true)
        let reopened = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        #expect(try await reopened.read { db in try String.fetchOne(db, sql: "SELECT value_json FROM preference WHERE key = 'k'") } == "42")
    }

    @Test("Backups: retenção dos 5 mais recentes")
    func backupRetention() async throws {
        let box = try Sandbox()
        defer { box.cleanup() }
        let database = try await MigrationRunner(root: box.root, appVersion: "0.0.1").open()
        let manager = BackupManager(root: box.root)
        for index in 0..<7 {
            try manager.backup(database.writer, appVersion: "0.0.1", now: Date(timeIntervalSince1970: 1_000 + Double(index)))
        }
        let names = try manager.backups().map(\.lastPathComponent)
        #expect(names.count == 5)
        #expect(names.first?.contains("19700101-001646") == true)   // o mais recente (1006 s)
    }
}
