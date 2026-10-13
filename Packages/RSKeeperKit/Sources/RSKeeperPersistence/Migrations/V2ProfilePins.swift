import GRDB

// REGRA: ver V1Initial.swift — migrações só executam SQL no próprio banco.

/// V2 (W1-T06, NST-02-03): conexões fixadas na sidebar (NST-03-01, "Fixadas").
/// `pinned_position` nulo = não fixada; a ordem das fixadas é a ordem crescente.
enum V2ProfilePins {
    static let identifier = "v2_profile_pins"

    static func migrate(_ db: Database) throws {
        try db.alter(table: "profile") { t in
            t.add(column: "pinned_position", .integer)
        }
        try db.create(index: "profile_pinned", on: "profile", columns: ["pinned_position"])
        try db.create(index: "profile_last_used", on: "profile", columns: ["last_used_at"])
    }
}
