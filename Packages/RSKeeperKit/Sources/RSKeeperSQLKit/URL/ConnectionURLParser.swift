import Foundation
import RSKeeperDomain

/// Senha extraída de uma URL colada. Nunca aparece em `description`, logs ou interpolação
/// (AR-IPC-08): vai direto para o rascunho de segredo e não volta ao campo como texto.
public struct PastedSecret: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    private let storage: String
    public init(_ value: String) { storage = value }
    /// Único acesso ao valor, no momento de gravar no `SecretStore`.
    public func reveal() -> String { storage }
    public var description: String { "<secret>" }
    public var debugDescription: String { "<secret>" }
}

/// Componentes de uma URL de conexão (NST-03-04; F-CONN-09).
public struct ParsedConnectionURL: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable { case postgresql, sqlite, mysql }

    public let kind: Kind
    public let host: String?
    public let port: UInt16?
    public let user: String?
    public let password: PastedSecret?
    public let database: String?
    /// Caminho do arquivo (`sqlite:`). O formulário ainda exige escolher o arquivo pelo painel (bookmark).
    public let filePath: String?
    /// `sslmode` mapeado; `nil` se ausente.
    public let tlsMode: TLSOptions.Mode?
    /// Parâmetros de consulta não reconhecidos (mostrados ao usuário; nunca aplicados em silêncio).
    public let ignoredParameters: [String]
}

public enum ConnectionURLError: Error, Sendable, Hashable {
    case invalidURL
    case unsupportedScheme(String)
    case invalidPort(String)
    case invalidSSLMode(String)
}

/// Parser de URL de conexão (`postgres://u:p@h:5432/db?sslmode=require`, `sqlite:///caminho.db`).
public enum ConnectionURLParser {
    public static func parse(_ text: String) throws(ConnectionURLError) -> ParsedConnectionURL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = trimmed.range(of: ":") else { throw .invalidURL }
        let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
        let kind: ParsedConnectionURL.Kind
        switch scheme {
        case "postgres", "postgresql": kind = .postgresql
        case "sqlite", "sqlite3", "file": kind = .sqlite
        case "mysql", "mariadb": kind = .mysql
        default: throw .unsupportedScheme(String(scheme))
        }

        if kind == .sqlite {
            // sqlite:///abs/path.db, sqlite:relativo.db, file:///…
            var path = String(trimmed[schemeEnd.upperBound...])
            if path.hasPrefix("//") { path.removeFirst(2) }
            path = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
            let decoded = path.removingPercentEncoding ?? path
            guard !decoded.isEmpty else { throw .invalidURL }
            return ParsedConnectionURL(kind: .sqlite, host: nil, port: nil, user: nil, password: nil, database: nil,
                                       filePath: decoded, tlsMode: nil, ignoredParameters: [])
        }

        guard let components = URLComponents(string: trimmed), components.host != nil || components.percentEncodedHost != nil else {
            throw .invalidURL
        }
        // Porta: URLComponents rejeita porta inválida devolvendo nil no init; validamos o intervalo.
        var port: UInt16?
        if let raw = components.port {
            guard (1...65_535).contains(raw) else { throw .invalidPort(String(raw)) }
            port = UInt16(raw)
        }
        let host = components.host.map { $0.hasPrefix("[") ? String($0.dropFirst().dropLast()) : $0 }
        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }

        var tlsMode: TLSOptions.Mode?
        var ignored: [String] = []
        for item in components.queryItems ?? [] {
            switch item.name.lowercased() {
            case "sslmode":
                guard let mode = sslMode(item.value ?? "") else { throw .invalidSSLMode(item.value ?? "") }
                tlsMode = mode
            default:
                ignored.append(item.name)
            }
        }
        return ParsedConnectionURL(
            kind: kind, host: host.flatMap { $0.isEmpty ? nil : $0 }, port: port,
            user: components.user.flatMap { $0.isEmpty ? nil : $0 },
            password: components.password.flatMap { $0.isEmpty ? nil : PastedSecret($0) },
            database: database.isEmpty ? nil : database, filePath: nil, tlsMode: tlsMode, ignoredParameters: ignored)
    }

    /// `sslmode` do libpq → modo do RSKeeper. `allow` vira `prefer` (o mais próximo que não rebaixa).
    private static func sslMode(_ value: String) -> TLSOptions.Mode? {
        switch value.lowercased() {
        case "disable": .disable
        case "allow", "prefer": .prefer
        case "require": .require
        case "verify-ca": .verifyCA
        case "verify-full": .verifyFull
        default: nil
        }
    }
}
