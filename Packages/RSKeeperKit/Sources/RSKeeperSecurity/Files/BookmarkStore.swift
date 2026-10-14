import Foundation
import RSKeeperDomain

/// Erros de acesso a arquivo concedido pelo usuário.
public enum FileGrantError: Error, Equatable, Sendable {
    /// O bookmark ficou obsoleto ou inválido: o usuário precisa escolher o arquivo de novo (aceite 2).
    case staleOrInvalid
    /// Caminho dentro da raiz de dados do próprio app (NT-SEC-07): nunca aceito como arquivo do usuário.
    case insideAppDataRoot
    case unknownGrant
}

/// Armazenamento dos dados de bookmark. A implementação persistente usa a tabela `file_grant` (W0-T22).
public protocol BookmarkStorage: Sendable {
    func save(_ data: Data, for id: UUID) async throws
    func load(_ id: UUID) async throws -> Data?
    func remove(_ id: UUID) async throws
}

/// Armazenamento em memória (testes e protótipos).
public actor InMemoryBookmarkStorage: BookmarkStorage {
    private var items: [UUID: Data] = [:]
    public init() {}
    public func save(_ data: Data, for id: UUID) async throws { items[id] = data }
    public func load(_ id: UUID) async throws -> Data? { items[id] }
    public func remove(_ id: UUID) async throws { items[id] = nil }
}

/// Abertura e fechamento de acesso com escopo de segurança (injetável para verificar o pareamento).
public protocol SecurityScopedAccessing: Sendable {
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct SystemSecurityScopedAccess: SecurityScopedAccessing {
    public init() {}
    public func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    public func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// Concessões persistentes de acesso a arquivo (W0-T21; porta DR-02; SPK-N07).
///
/// O caminho só entra por um painel do sistema e vira bookmark com escopo de segurança (funciona com e
/// sem sandbox, verificado no SPK-N07). O app nunca abre um caminho cru vindo do perfil.
public struct BookmarkStore: Sendable {
    private let storage: any BookmarkStorage
    private let access: any SecurityScopedAccessing
    private let appDataRoot: DataRoot

    public init(storage: any BookmarkStorage, appDataRoot: DataRoot, access: any SecurityScopedAccessing = SystemSecurityScopedAccess()) {
        self.storage = storage
        self.appDataRoot = appDataRoot
        self.access = access
    }

    /// Cria a concessão a partir de uma URL escolhida pelo usuário num painel.
    public func grant(forUserSelected url: URL) async throws -> FileGrant {
        guard !appDataRoot.contains(url) else { throw FileGrantError.insideAppDataRoot }
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        let grant = FileGrant(id: UUID(), displayPath: url.path)
        try await storage.save(data, for: grant.id)
        return grant
    }

    /// Executa `body` com acesso ao arquivo; `start`/`stop` sempre pareados, inclusive em erro (aceite 3).
    public func withAccess<T: Sendable>(to grant: FileGrant, _ body: (URL) async throws -> T) async throws -> T {
        guard let data = try await storage.load(grant.id) else { throw FileGrantError.unknownGrant }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw FileGrantError.staleOrInvalid
        }
        guard !stale else { throw FileGrantError.staleOrInvalid }
        guard !appDataRoot.contains(url) else { throw FileGrantError.insideAppDataRoot }
        let started = access.startAccessing(url)
        defer { if started { access.stopAccessing(url) } }
        return try await body(url)
    }

    /// Acesso de longa duração (uma sessão SQLite mantém o arquivo aberto): resolve o bookmark, inicia o
    /// escopo e devolve a URL. O escopo fica aberto até `endLongLivedAccess` ou o fim do processo.
    public func beginLongLivedAccess(to grant: FileGrant, tracker: ScopedAccessTracker) async throws -> URL {
        guard let data = try await storage.load(grant.id) else { throw FileGrantError.unknownGrant }
        var stale = false
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw FileGrantError.staleOrInvalid
        }
        guard !stale else { throw FileGrantError.staleOrInvalid }
        guard !appDataRoot.contains(url) else { throw FileGrantError.insideAppDataRoot }
        await tracker.begin(grant.id, url: url, access: access)
        return url
    }

    public func endLongLivedAccess(to grant: FileGrant, tracker: ScopedAccessTracker) async {
        await tracker.end(grant.id, access: access)
    }

    /// Revoga a concessão (o arquivo em si não é tocado).
    public func revoke(_ grant: FileGrant) async throws { try await storage.remove(grant.id) }
}

/// Escopos de acesso abertos por concessão, com contagem (duas sessões no mesmo arquivo).
public actor ScopedAccessTracker {
    private var open: [UUID: (url: URL, count: Int, started: Bool)] = [:]
    public init() {}

    func begin(_ id: UUID, url: URL, access: any SecurityScopedAccessing) {
        if let entry = open[id] {
            open[id] = (entry.url, entry.count + 1, entry.started)
        } else {
            open[id] = (url, 1, access.startAccessing(url))
        }
    }

    func end(_ id: UUID, access: any SecurityScopedAccessing) {
        guard let entry = open[id] else { return }
        if entry.count > 1 {
            open[id] = (entry.url, entry.count - 1, entry.started)
        } else {
            open[id] = nil
            if entry.started { access.stopAccessing(entry.url) }
        }
    }

    public var openCount: Int { open.count }
}
