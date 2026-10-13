import Foundation

/// Ambiente de execução do app (Info.plist `RSKEnvironment`, definido por configuração Xcode).
public enum AppEnvironmentKind: String, Sendable, CaseIterable {
    case dev, test, prod

    /// Nome da pasta de dados em `Application Support`.
    public var folderName: String {
        switch self {
        case .dev: "RSKeeper Dev"
        case .test: "RSKeeper Test"
        case .prod: "RSKeeper"
        }
    }

    /// Sufixo do bundle ID (centralizado em Config/BundleIdentifiers.xcconfig no app).
    public var bundleIDSuffix: String {
        switch self {
        case .dev: ".dev"
        case .test: ".test"
        case .prod: ""
        }
    }
}

/// Raiz única de dados por ambiente (W0-T13). **Todos** os caminhos do app derivam daqui.
///
/// - Com sandbox: `Application Support` já é o do container do bundle ID.
/// - Sem sandbox: `~/Library/Application Support/RSKeeper[ Dev| Test]`.
/// - Test: sempre a raiz temporária validada pela guarda (`-RSKeeperDataRoot`).
public struct DataRoot: Hashable, Sendable {
    public let url: URL

    /// O caminho é mantido como recebido (sem `standardizedFileURL`, que removeria `/private`).
    public init(url: URL) { self.url = url.absoluteURL }

    /// Raiz padrão do ambiente a partir de `Application Support` (container ou não).
    public static func standard(for environment: AppEnvironmentKind, applicationSupport: URL) -> DataRoot {
        DataRoot(url: applicationSupport.appendingPathComponent(environment.folderName, isDirectory: true))
    }

    /// `Application Support` do processo atual (no sandbox, aponta para o container).
    public static func currentApplicationSupport() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // MARK: Caminhos derivados (docs/native/05 e DR-23 adaptado)

    public var databaseDirectory: URL { url.appendingPathComponent("data", isDirectory: true) }
    public var databaseFile: URL { databaseDirectory.appendingPathComponent("app.db") }
    public var backupsDirectory: URL { url.appendingPathComponent("backups", isDirectory: true) }
    public var draftsDirectory: URL { url.appendingPathComponent("drafts", isDirectory: true) }
    public var temporaryDirectory: URL { url.appendingPathComponent("tmp", isDirectory: true) }
    public var snapshotsDirectory: URL { url.appendingPathComponent("snapshots", isDirectory: true) }

    /// Todos os diretórios gerenciados pelo app.
    public var managedDirectories: [URL] { [databaseDirectory, backupsDirectory, draftsDirectory, temporaryDirectory] }

    /// Indica se `candidate` está dentro desta raiz (após resolver symlinks).
    public func contains(_ candidate: URL) -> Bool {
        let root = url.resolvingSymlinksInPath().path
        let path = candidate.standardizedFileURL.resolvingSymlinksInPath().path
        return path == root || path.hasPrefix(root + "/")
    }

    /// Cria a raiz e os diretórios gerenciados com permissão 0700 (DR-24 adaptado).
    public func prepare(fileManager: FileManager = .default) throws {
        for directory in [url] + managedDirectories {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
    }

    /// Limpa sobras de `tmp/` de sessões anteriores (varredura no boot, DR-24).
    public func sweepTemporaryFiles(fileManager: FileManager = .default) throws -> Int {
        guard fileManager.fileExists(atPath: temporaryDirectory.path) else { return 0 }
        let items = try fileManager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: nil)
        for item in items { try fileManager.removeItem(at: item) }
        return items.count
    }
}
