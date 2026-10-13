import Foundation
import GRDB
import RSKeeperSecurity

/// Backups do banco local feitos pelo **migrador** (nunca por uma migração), em `backups/`,
/// com retenção dos 5 mais recentes (docs/native/05 §5, item 3).
public struct BackupManager: Sendable {
    public static let retention = 5

    public let root: DataRoot

    public init(root: DataRoot) { self.root = root }

    /// Copia o banco com `VACUUM INTO` e aplica a retenção. Retorna o arquivo criado.
    @discardableResult
    public func backup(_ writer: some DatabaseWriter, appVersion: String, now: Date = Date()) throws -> URL {
        let directory = root.backupsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let stamp = Self.timestamp(now)
        let safeVersion = appVersion.filter { $0.isLetter || $0.isNumber || $0 == "." }
        var destination = directory.appendingPathComponent("app-\(safeVersion)-\(stamp).db")
        var counter = 1
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = directory.appendingPathComponent("app-\(safeVersion)-\(stamp)-\(counter).db")
            counter += 1
        }
        let target = destination.path
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [target])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target)
        try prune()
        return destination
    }

    /// Backups existentes, do mais recente para o mais antigo.
    public func backups() throws -> [URL] {
        let directory = root.backupsDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
            .filter { $0.pathExtension == "db" && $0.lastPathComponent.hasPrefix("app-") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    /// Mantém só os `retention` mais recentes.
    public func prune() throws {
        for old in try backups().dropFirst(Self.retention) {
            try FileManager.default.removeItem(at: old)
        }
    }

    /// Restaura o backup mais recente sobre o banco. **Só com consentimento explícito** (NT-MIG-07).
    public func restoreLatestBackup(consent: Bool) throws -> URL {
        guard consent else { throw PersistenceError.consentRequired }
        guard let latest = try backups().first else { throw PersistenceError.noBackupAvailable }
        let database = root.databaseFile
        for suffix in ["", "-wal", "-shm"] {
            let path = database.path + suffix
            if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
        }
        try FileManager.default.copyItem(at: latest, to: database)
        return latest
    }

    /// `yyyyMMdd-HHmmss-SSS` em UTC: ordena lexicograficamente pela data.
    static func timestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }
}

/// Erros da persistência local.
public enum PersistenceError: Error, Equatable, Sendable {
    case consentRequired
    case noBackupAvailable
    case corrupted
    /// Escrita recusada: banco em modo somente leitura (mais novo ou em recuperação).
    case readOnlyDatabase
}
