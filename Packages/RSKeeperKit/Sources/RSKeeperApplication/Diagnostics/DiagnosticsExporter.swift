import Foundation
import RSKeeperDomain
import RSKeeperSecurity

/// Pacote de diagnóstico exportado manualmente pelo usuário (W0-T15; RNF-OBS-02; ADR-N23).
///
/// Contém **só metadados**: versão, SO, arquitetura, ambiente e códigos de erro recentes.
/// Nunca: caminhos do usuário, hosts, SQL, nomes de conexão, segredos. Nenhum envio de rede —
/// o exportador só produz bytes; quem grava é o usuário, num painel de salvar.
public struct DiagnosticsReport: Codable, Equatable, Sendable {
    public struct ErrorEntry: Codable, Equatable, Sendable {
        public let code: String
        public let count: Int
    }

    public let appVersion: String
    public let build: String
    public let osVersion: String
    public let architecture: String
    public let environment: String
    public let sandboxed: Bool
    public let recentErrorCodes: [ErrorEntry]
}

public struct DiagnosticsExporter: Sendable {
    public struct Context: Sendable {
        public var appVersion: String
        public var build: String
        public var environment: AppEnvironmentKind
        public var sandboxed: Bool
        public init(appVersion: String, build: String, environment: AppEnvironmentKind, sandboxed: Bool) {
            self.appVersion = appVersion
            self.build = build
            self.environment = environment
            self.sandboxed = sandboxed
        }
    }

    private let context: Context

    public init(context: Context) { self.context = context }

    /// Produz o relatório a partir dos erros recentes, mantendo **só o código** de cada erro.
    public func report(recentErrors: [RSKeeperError], operatingSystem: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                       architecture: String = Self.currentArchitecture) -> DiagnosticsReport {
        var counts: [String: Int] = [:]
        for error in recentErrors { counts[Self.code(of: error), default: 0] += 1 }
        let entries = counts.sorted { $0.key < $1.key }.map { DiagnosticsReport.ErrorEntry(code: $0.key, count: $0.value) }
        let os = "\(operatingSystem.majorVersion).\(operatingSystem.minorVersion).\(operatingSystem.patchVersion)"
        return DiagnosticsReport(appVersion: context.appVersion, build: context.build, osVersion: os,
                                 architecture: architecture, environment: context.environment.rawValue,
                                 sandboxed: context.sandboxed, recentErrorCodes: entries)
    }

    /// JSON estável (chaves ordenadas) do relatório.
    public func export(recentErrors: [RSKeeperError]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report(recentErrors: recentErrors))
    }

    /// Código do erro, sem a mensagem (que pode conter dados do servidor).
    static func code(of error: RSKeeperError) -> String {
        switch error {
        case .validation: "validation"
        case .notFound(let reason): "notFound.\(reason.rawValue)"
        case .timeout: "timeout"
        case .cancelled: "cancelled"
        case .connection: "connection"
        case .auth: "auth"
        case .driver(let code, _): "driver.\(code.filter { $0.isLetter || $0.isNumber }.prefix(16))"
        case .permission: "permission"
        case .readOnly: "readOnly"
        case .confirmationRequired: "confirmationRequired"
        case .conflict(let reason): "conflict.\(reason.rawValue)"
        case .unsupported: "unsupported"
        case .outcomeUnknown(let reason): "outcomeUnknown.\(reason.rawValue)"
        case .internal: "internal"
        }
    }

    public static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "other"
        #endif
    }
}
