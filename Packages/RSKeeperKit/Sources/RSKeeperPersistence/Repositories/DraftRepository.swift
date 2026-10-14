import CryptoKit
import Foundation
import GRDB
import RSKeeperDomain

/// Registro de aba para recuperação (NST-01-05): o mínimo para reabrir depois de um encerramento forçado.
public struct TabRecord: Hashable, Sendable {
    public var id: TabID
    public var profileID: ProfileID
    public var window: WindowID
    public var kind: TabKind
    public var title: String
    public var position: Int

    public init(id: TabID, profileID: ProfileID, window: WindowID, kind: TabKind, title: String, position: Int) {
        self.id = id
        self.profileID = profileID
        self.window = window
        self.kind = kind
        self.title = title
        self.position = position
    }
}

/// Aba recuperada no próximo boot, com o texto do rascunho.
public struct RecoveredTab: Hashable, Sendable {
    public let tab: TabRecord
    public let text: String?
    /// O texto difere do último salvo: a aba volta marcada como não salva (RNF-REL-04).
    public let isUnsaved: Bool
}

/// Abas e rascunhos (NST-01-05; 03 §15). Gravação transacional no GRDB.
public struct DraftRepository: Sendable {
    private let database: AppDatabase
    public init(database: AppDatabase) { self.database = database }

    /// Hash do texto salvo, para decidir "não salvo" na recuperação.
    public static func hash(_ text: String) -> [UInt8] { Array(SHA256.hash(data: Data(text.utf8))) }

    /// Grava a aba e, se houver, o rascunho do texto (uma transação).
    public func save(_ tab: TabRecord, text: String?, savedTextHash: [UInt8]?) async throws(RSKeeperError) {
        let kind = String(decoding: (try? JSONEncoder().encode(tab.kind)) ?? Data("{}".utf8), as: UTF8.self)
        let dirty = text.map { savedTextHash != Self.hash($0) } ?? false
        do {
            try await database.write { db in
                let now = Date()
                try db.execute(sql: """
                    INSERT INTO tab (id, profile_id, owner_window, kind_json, title, position, is_dirty, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET kind_json = excluded.kind_json, title = excluded.title,
                        position = excluded.position, is_dirty = excluded.is_dirty, updated_at = excluded.updated_at
                    """, arguments: [tab.id.raw, tab.profileID.raw, tab.window.raw, kind, tab.title, tab.position, dirty, now])
                guard let text else { return }
                try db.execute(sql: """
                    INSERT INTO draft (id, tab_id, profile_id, text, saved_text_hash, updated_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET text = excluded.text, saved_text_hash = excluded.saved_text_hash,
                        updated_at = excluded.updated_at
                    """, arguments: [tab.id.raw, tab.id.raw, tab.profileID.raw, text, savedTextHash.map { Data($0) }, now])
            }
        } catch {
            throw PersistenceErrors.map(error)
        }
    }

    /// Aba fechada: some da recuperação.
    public func remove(_ tab: TabID) async throws(RSKeeperError) {
        do {
            try await database.write { db in
                try db.execute(sql: "DELETE FROM draft WHERE id = ?", arguments: [tab.raw])
                try db.execute(sql: "DELETE FROM tab WHERE id = ?", arguments: [tab.raw])
            }
        } catch {
            throw PersistenceErrors.map(error)
        }
    }

    /// Tudo o que restaurar no boot, em ordem de posição.
    public func recoverable() async throws(RSKeeperError) -> [RecoveredTab] {
        do {
            return try await database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT t.id, t.profile_id, t.owner_window, t.kind_json, t.title, t.position, d.text, d.saved_text_hash
                    FROM tab t LEFT JOIN draft d ON d.id = t.id ORDER BY t.position
                    """).compactMap { row -> RecoveredTab? in
                    guard let kind = try? JSONDecoder().decode(TabKind.self, from: Data((row["kind_json"] as String).utf8)) else { return nil }
                    let record = TabRecord(id: TabID(raw: row["id"]), profileID: ProfileID(raw: row["profile_id"]),
                                           window: WindowID(raw: row["owner_window"]), kind: kind, title: row["title"], position: row["position"])
                    let text: String? = row["text"]
                    let saved: Data? = row["saved_text_hash"]
                    return RecoveredTab(tab: record, text: text, isUnsaved: text.map { saved.map(Array.init) != Self.hash($0) } ?? false)
                }
            }
        } catch {
            throw PersistenceErrors.map(error)
        }
    }
}
