import Foundation
import GRDB
import RSKeeperSecurity

/// Bookmarks persistidos na tabela `file_grant` (W0-T21 previa; W1-T14 implementa).
/// O caminho de exibição vem no perfil (`FileGrant.displayPath`); aqui fica só o bookmark.
public struct DatabaseBookmarkStorage: BookmarkStorage {
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    public func save(_ data: Data, for id: UUID) async throws {
        try await database.write { db in
            try db.execute(sql: """
                INSERT INTO file_grant (id, profile_id, purpose, bookmark, display_path, read_only, created_at)
                VALUES (?, NULL, 'sqliteFile', ?, '', 0, ?)
                ON CONFLICT(id) DO UPDATE SET bookmark = excluded.bookmark
                """, arguments: [id, data, Date()])
        }
    }

    public func load(_ id: UUID) async throws -> Data? {
        try await database.read { db in try Data.fetchOne(db, sql: "SELECT bookmark FROM file_grant WHERE id = ?", arguments: [id]) }
    }

    public func remove(_ id: UUID) async throws {
        try await database.write { db in try db.execute(sql: "DELETE FROM file_grant WHERE id = ?", arguments: [id]) }
    }
}
