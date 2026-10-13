import GRDB

// REGRA (lição U-22; NT-MIG-05): arquivos desta pasta só podem executar SQL no próprio banco.
// Proibido importar Foundation/os/Darwin ou usar FileManager, FileHandle, Process, URL, logs em
// arquivo. O teste MigrationRulesTests verifica isso.

/// Migração v1: tabelas do núcleo (docs/native/05 §4). As tabelas da expansão (v2_*) não entram aqui.
enum V1Initial {
    static let identifier = "v1_initial"

    static func migrate(_ db: Database) throws {
        try db.create(table: "folder") { t in
            t.column("id", .blob).primaryKey()
            t.column("name", .text).notNull()
            t.column("parent_id", .blob).references("folder", onDelete: .cascade)
            t.column("position", .integer).notNull().defaults(to: 0)
            t.column("expanded", .boolean).notNull().defaults(to: true)
            t.column("kind", .text).notNull().check(sql: "kind IN ('connection', 'query')")
        }
        try db.create(table: "profile") { t in
            t.column("id", .blob).primaryKey()
            t.column("name", .text).notNull()
            t.column("driver_id", .text).notNull()
            t.column("folder_id", .blob).references("folder", onDelete: .setNull)
            t.column("label_color", .text).notNull().defaults(to: "none")
            t.column("environment", .text).notNull()
                .check(sql: "environment IN ('local', 'development', 'testing', 'staging', 'production', 'custom')")
            t.column("environment_custom_id", .blob)
            t.column("environment_confirmed", .boolean).notNull().defaults(to: false)
            t.column("read_only", .boolean).notNull().defaults(to: false)
            t.column("target_json", .text).notNull()
            t.column("tls_json", .text)
            t.column("ssh_json", .text)
            t.column("default_database", .text)
            t.column("driver_options_json", .text).notNull().defaults(to: "{}")
            t.column("save_passwords", .boolean).notNull().defaults(to: true)
            t.column("is_draft", .boolean).notNull().defaults(to: false)
            t.column("revision", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
            t.column("last_used_at", .datetime)
        }
        // Unicidade por pasta sem distinguir maiúsculas, só para perfis salvos (inv. 2.1-6).
        try db.execute(sql: """
            CREATE UNIQUE INDEX profile_unique_name ON profile(ifnull(folder_id, x''), name COLLATE NOCASE)
            WHERE is_draft = 0
            """)
        try db.create(table: "secret_ref") { t in
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("purpose", .text).notNull()
            t.column("fingerprint", .blob)
            t.column("state", .text).notNull().check(sql: "state IN ('stored', 'prompt', 'missing')")
            t.primaryKey(["profile_id", "purpose"])
        }
        try db.create(table: "file_grant") { t in
            t.column("id", .blob).primaryKey()
            t.column("profile_id", .blob).references("profile", onDelete: .cascade)
            t.column("purpose", .text).notNull()
                .check(sql: "purpose IN ('sqliteFile', 'tlsCA', 'tlsCert', 'tlsKey', 'sshKey')")
            t.column("bookmark", .blob).notNull()
            t.column("display_path", .text).notNull()
            t.column("read_only", .boolean).notNull().defaults(to: false)
            t.column("created_at", .datetime).notNull()
            t.uniqueKey(["profile_id", "purpose"])
        }
        for table in ["pin", "hidden"] {
            try db.create(table: table) { t in
                t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
                t.column("entity_json", .text).notNull()
                t.column("kind", .text).notNull().check(sql: "kind IN ('entity', 'schema')")
                t.column("position", .integer).notNull().defaults(to: 0)
                t.primaryKey(["profile_id", "entity_json"])
            }
        }
        try db.create(table: "saved_query") { t in
            t.column("id", .blob).primaryKey()
            t.column("name", .text).notNull()
            t.column("text", .text).notNull()
            t.column("folder_id", .blob).references("folder", onDelete: .setNull)
            t.column("profile_id", .blob).references("profile", onDelete: .setNull)
            t.column("revision", .integer).notNull().defaults(to: 0)
            t.column("created_at", .datetime).notNull()
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(table: "history") { t in
            t.column("execution_id", .blob).primaryKey()
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("text", .text)
            t.column("reports_json", .text).notNull()
            t.column("outcome", .text).notNull()
            t.column("started_at", .datetime).notNull()
            t.column("duration_ms", .integer).notNull()
        }
        try db.create(index: "history_by_profile_time", on: "history", columns: ["profile_id", "started_at"])
        try db.create(table: "tab") { t in
            t.column("id", .blob).primaryKey()
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("owner_window", .blob).notNull()
            t.column("kind_json", .text).notNull()
            t.column("title", .text).notNull()
            t.column("title_scope", .text)
            t.column("position", .integer).notNull()
            t.column("is_dirty", .boolean).notNull().defaults(to: false)
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(table: "closed_tab") { t in
            t.column("id", .blob).primaryKey()
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("kind_json", .text).notNull()
            t.column("closed_at", .datetime).notNull()
        }
        try db.create(table: "draft") { t in
            t.column("id", .blob).primaryKey()
            t.column("tab_id", .blob).references("tab", onDelete: .setNull)
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("text", .text).notNull()
            t.column("saved_text_hash", .blob)
            t.column("updated_at", .datetime).notNull()
        }
        try db.create(table: "grid_layout") { t in
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("entity_json", .text).notNull()
            t.column("layout_json", .text).notNull()
            t.primaryKey(["profile_id", "entity_json"])
        }
        try db.create(table: "preference") { t in
            t.column("key", .text).primaryKey()
            t.column("value_json", .text).notNull()
        }
        try db.create(table: "workspace_layout") { t in
            t.column("profile_id", .blob).notNull().references("profile", onDelete: .cascade)
            t.column("window_key", .text).notNull()
            t.column("layout_json", .text).notNull()
            t.primaryKey(["profile_id", "window_key"])
        }
        try db.create(table: "shortcut_override") { t in
            t.column("command_id", .text).primaryKey()
            t.column("key_equivalent", .text).notNull()
            t.column("modifiers", .integer).notNull()
        }
        try db.create(table: "known_host") { t in
            t.column("host", .text).notNull()
            t.column("port", .integer).notNull()
            t.column("key_type", .text).notNull()
            t.column("fingerprint_sha256", .blob).notNull()
            t.column("added_at", .datetime).notNull()
            t.primaryKey(["host", "port", "key_type"])
        }
        try db.create(table: "job_log") { t in
            t.column("job_id", .blob).primaryKey()
            t.column("kind", .text).notNull()
            t.column("state", .text).notNull()
            t.column("partial_path", .text)
            t.column("started_at", .datetime).notNull()
            t.column("finished_at", .datetime)
            t.column("summary_json", .text)
        }
    }
}
