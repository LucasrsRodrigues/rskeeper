import Foundation
import os

/// Valor de campo de log. Por padrão é **privado**: aparece como `<private>` fora de depuração (NT-SEC-20).
public struct LogField: Sendable {
    public enum Privacy: Sendable { case `private`, `public` }
    let value: String
    let privacy: Privacy

    /// Valor dinâmico privado (padrão). Também é redigido antes de ir para o OSLog.
    public static func `private`(_ value: String) -> LogField { LogField(value: value, privacy: .private) }
    /// Só para valores não sensíveis e de baixa cardinalidade (códigos, contagens, nomes de estado).
    public static func `public`(_ value: String) -> LogField { LogField(value: value, privacy: .public) }
    /// Texto de consulta SQL: sempre privado e redigido (aceite 4).
    public static func query(_ sql: String) -> LogField { LogField(value: sql, privacy: .private) }
}

/// Destino adicional de log, usado em testes para verificar o canário sem depender de `log show`.
public protocol LogSink: Sendable {
    func write(level: OSLogType, category: String, event: String, rendered: String)
}

/// Logger do RSKeeper sobre OSLog (W0-T14; ADR-N23).
///
/// - Subsistema por ambiente: `app.rskeeper.RSKeeper[.dev|.test]` (aceite 1).
/// - Campos dinâmicos `.private` por padrão; todo valor passa pelo `Redactor` (aceites 2–4).
/// - Não há arquivo de log próprio nem código que apague logs (aceite 5): a retenção é do sistema.
public struct RKLogger: Sendable {
    public let subsystem: String
    public let category: String
    private let logger: Logger
    private let redactor: Redactor
    private let sink: (any LogSink)?

    public init(subsystem: String, category: String, redactor: Redactor = Redactor(), sink: (any LogSink)? = nil) {
        self.subsystem = subsystem
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
        self.redactor = redactor
        self.sink = sink
    }

    /// Subsistema do ambiente a partir do bundle ID base e do ambiente.
    public static func subsystem(bundleIDBase: String, environment: AppEnvironmentKind) -> String {
        bundleIDBase + environment.bundleIDSuffix
    }

    public func info(_ event: StaticString, _ fields: [String: LogField] = [:]) { log(.info, event, fields) }
    public func notice(_ event: StaticString, _ fields: [String: LogField] = [:]) { log(.default, event, fields) }
    public func error(_ event: StaticString, _ fields: [String: LogField] = [:]) { log(.error, event, fields) }
    public func debug(_ event: StaticString, _ fields: [String: LogField] = [:]) { log(.debug, event, fields) }

    private func log(_ level: OSLogType, _ event: StaticString, _ fields: [String: LogField]) {
        let eventName = "\(event)"
        let publicPart = fields.filter { $0.value.privacy == .public }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(redactor.redact($0.value.value))" }
            .joined(separator: " ")
        let privatePart = fields.filter { $0.value.privacy == .private }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(redactor.redact($0.value.value))" }
            .joined(separator: " ")
        logger.log(level: level, "\(eventName, privacy: .public) \(publicPart, privacy: .public) \(privatePart, privacy: .private)")
        sink?.write(level: level, category: category, event: eventName,
                    rendered: "\(eventName) \(publicPart) \(privatePart.isEmpty ? "" : "<private>")")
    }
}
