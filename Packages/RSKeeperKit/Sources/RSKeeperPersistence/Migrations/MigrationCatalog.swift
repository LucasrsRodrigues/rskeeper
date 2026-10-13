import GRDB

// REGRA: ver V1Initial.swift — migrações só executam SQL no próprio banco.

/// Uma migração nomeada e versionada. Só avança (não há migração de volta).
public struct Migration: Sendable {
    public let identifier: String
    let body: @Sendable (Database) throws -> Void

    public init(identifier: String, body: @escaping @Sendable (Database) throws -> Void) {
        self.identifier = identifier
        self.body = body
    }
}

/// Catálogo ordenado de migrações do app.
public enum MigrationCatalog {
    /// Migrações do produto, em ordem.
    public static let standard: [Migration] = [
        Migration(identifier: V1Initial.identifier, body: V1Initial.migrate),
        Migration(identifier: V2ProfilePins.identifier, body: V2ProfilePins.migrate),
    ]
}
