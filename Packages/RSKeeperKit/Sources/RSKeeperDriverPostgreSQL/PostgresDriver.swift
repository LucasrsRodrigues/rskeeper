import Foundation
import PostgresNIO
import RSKeeperDomain
import RSKeeperDriversCore

/// Driver PostgreSQL (NST-04-03; ADR-N16 com as 6 condições do SPK-N03).
///
/// A PostgresNIO é usada **só como transporte** (`PostgresConnection`). O driver implementa:
/// cancelamento guardado por marcador, decodificador binário por OID, guarda de conexão fechada,
/// recusa de `COPY`, somente leitura em camadas e reset de sessão. O pool fica na `DatabaseSession`.
public struct PostgresDriver: DriverFactory {
    public let descriptor = DriverDescriptor(
        id: .postgresql, displayName: "PostgreSQL", targetKind: .server,
        capabilities: DriverCapabilities(
            cancel: .server, transactions: true, savepoints: true, transactionalDDL: true,
            schemas: true, changeDatabaseInSession: false, ilike: true, returning: true,
            streaming: .cursor, readOnly: .perTransaction,
            tls: false,                                    // TLS entra na onda 2 (NST-04-06)
            ssh: false, statementTimeout: .server("statement_timeout"),
            materializedViews: true, routines: true, triggers: true, partitions: true,
            explain: true, explainAnalyze: true, health: false, introspection: .basic),
        dialect: PostgresDialect())

    public init() {}

    public func validate(_ target: ConnectionTarget) throws(DriverError) {
        guard target.kind == .server else {
            throw .validation(RedactedMessage(alreadyRedacted: "O PostgreSQL conecta a um servidor, não a um arquivo."))
        }
    }

    public func open(_ target: ResolvedTarget, options: OpenOptions) async throws(DriverError) -> any PhysicalConnection {
        guard case .server(let host, let port, let user, let password, let database) = target else {
            throw .validation(RedactedMessage(alreadyRedacted: "O PostgreSQL conecta a um servidor, não a um arquivo."))
        }
        if let tls = options.tls, tls.mode != .disable { throw .unsupported(.tls) }
        let endpoint = PGEndpoint(host: host, port: Int(port), user: user ?? "postgres", password: password,
                                  database: database, connectTimeoutSeconds: options.connectTimeoutSeconds)
        return try await PGConnection.open(endpoint, readOnly: options.readOnly)
    }
}

/// Dialeto do PostgreSQL: identificadores entre aspas duplas, placeholders `$n`.
public struct PostgresDialect: Dialect {
    public init() {}
    public var placeholderStyle: PlaceholderStyle { .dollarNumbered }

    public func quoteIdentifier(_ part: String) throws(DriverError) -> String {
        guard !part.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador vazio.")) }
        guard !part.contains("\u{0}") else { throw .validation(RedactedMessage(alreadyRedacted: "Identificador com NUL.")) }
        return "\"" + part.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public func limitClause(limit: Int, offset: Int) -> String { "LIMIT \(limit) OFFSET \(offset)" }
}

/// Dados para abrir conexões (a principal e as auxiliares de cancelamento).
struct PGEndpoint: Sendable {
    let host: String
    let port: Int
    let user: String
    let password: SecretValue?
    let database: String?
    let connectTimeoutSeconds: Int

    func configuration() -> PostgresConnection.Configuration {
        var configuration = PostgresConnection.Configuration(
            host: host, port: port, username: user, password: password?.reveal(), database: database, tls: .disable)
        configuration.options.connectTimeout = .seconds(Int64(connectTimeoutSeconds))
        return configuration
    }
}

/// Erros da PostgresNIO/NIO → `DriverError` (doc 04 §2.5; SQLSTATE confirmado no SPK-N03).
enum PGErrors {
    static func map(_ error: any Error, markerLength: Int = 0) -> DriverError {
        switch error {
        case let error as DriverError: return error
        case is CancellationError: return .cancelled
        case let error as PSQLError:
            guard let state = error.serverInfo?[.sqlState] else {
                // Sem resposta do servidor: rede, socket fechado, protocolo.
                switch error.code {
                case .queryCancelled: return .cancelled
                default: return .connection(RedactedMessage(alreadyRedacted: "Conexão com o servidor PostgreSQL falhou ou foi encerrada."))
                }
            }
            let message = RedactedMessage(alreadyRedacted: redact(error.serverInfo?[.message] ?? "Erro do PostgreSQL."))
            switch state {
            case "28P01", "28000": return .authentication
            case "25006": return .readOnly
            case "57014": return .cancelled
            case "53300": return .connectionLimit
            case _ where state.hasPrefix("08"): return .connection(message)
            case _ where state.hasPrefix("23"): return .constraint(message)
            case _ where state.hasPrefix("42"):
                let position = error.serverInfo?[.position].flatMap(Int.init).map { max(1, $0 - markerLength) }
                return .syntaxOrSemantic(message, position: position)
            default: return .driver(code: state, message)
            }
        default:
            // Erros de NIO (conexão recusada, DNS, timeout de conexão) chegam sem SQLSTATE.
            let text = String(describing: error).lowercased()
            if text.contains("timeout") || text.contains("timed out") { return .timedOut }
            return .connection(RedactedMessage(alreadyRedacted: "Não foi possível conectar ao servidor PostgreSQL."))
        }
    }

    /// Remove o conteúdo de literais `'…'` da mensagem do servidor (valores do usuário).
    static func redact(_ message: String) -> String {
        var result = ""
        var insideLiteral = false
        for character in message {
            if character == "'" {
                result.append(character)
                if !insideLiteral { result.append("…") }
                insideLiteral.toggle()
            } else if !insideLiteral {
                result.append(character)
            }
        }
        return result
    }
}
