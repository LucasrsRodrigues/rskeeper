import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperSQLKit

/// O que executar (NST-07-02, crit. 1).
public enum ExecutionScope: Sendable, Equatable {
    case all
    /// Instrução sob o cursor (offset UTF-16). Entre instruções → indisponível.
    case current(cursor: Int)
    /// Intervalo UTF-16 selecionado.
    case selection(Range<Int>)
}

/// Plano de execução: instruções prontas para a sessão, com risco e intervalo no editor.
public struct ExecutionPlan: Sendable {
    public let statements: [PlannedStatement]
    public let classified: [ClassifiedStatement]
}

/// Planeja e executa consultas do editor (NST-07-02).
///
/// Planejar é puro e síncrono: divide pelo dialeto, classifica (DR-11), aplica a camada 1 do
/// somente leitura (DR-12), recusa `COPY` de protocolo e liga `:parâmetros` no estilo do driver.
/// A confirmação de risco (NST-07-04) entra entre o plano e a execução.
public struct ExecuteQueryUseCase: Sendable {
    public init() {}

    public static func dialect(for driver: DriverID) throws(RSKeeperError) -> SQLDialect {
        switch driver {
        case .sqlite: .sqlite
        case .postgresql: .postgresql
        default: throw .unsupported(RedactedMessage(alreadyRedacted: "Driver sem dialeto SQL nesta versão."))
        }
    }

    /// "Executar atual" disponível? (o botão e o menu consultam isto; [CONFIRMADO S3] 'Run Current unavailable').
    public static func hasCurrentStatement(_ text: String, cursor: Int, dialect: SQLDialect) -> Bool {
        StatementSplitter.split(text, dialect: dialect).statement(atUTF16Offset: cursor) != nil
    }

    public func plan(_ text: String, scope: ExecutionScope, dialect: SQLDialect, placeholders: PlaceholderStyle,
                     readOnly: Bool, parameters: [String: BindValue] = [:]) throws(RSKeeperError) -> ExecutionPlan {
        var split = StatementSplitter.split(text, dialect: dialect)
        var offset = 0
        var chosen: [SQLStatement]
        switch scope {
        case .all:
            chosen = split.statements
        case .current(let cursor):
            guard let statement = split.statement(atUTF16Offset: cursor) else {
                throw .validation(RedactedMessage(alreadyRedacted: "Não há instrução sob o cursor."))
            }
            chosen = [statement]
        case .selection(let range):
            // A seleção é dividida sozinha: um trecho de instrução vira a instrução que o usuário marcou.
            let units = Array(text.utf16)
            let clamped = max(0, range.lowerBound)..<min(units.count, range.upperBound)
            split = StatementSplitter.split(String(decoding: units[clamped], as: UTF16.self), dialect: dialect)
            chosen = split.statements
            offset = clamped.lowerBound
        }
        guard !chosen.isEmpty else { throw .validation(RedactedMessage(alreadyRedacted: "Nenhuma instrução para executar.")) }

        let style: SQLPlaceholderStyle = placeholders == .dollarNumbered ? .dollarNumbered : .questionMark
        var planned: [PlannedStatement] = []
        var classifiedAll: [ClassifiedStatement] = []
        var missing: Set<String> = []
        for statement in chosen {
            let classified = RiskClassifier.classify(statement, in: split.lexed)
            if classified.blocked == .copyProtocol {
                throw .validation(RedactedMessage(alreadyRedacted: "COPY FROM STDIN / TO STDOUT não é suportado no editor; use a exportação."))
            }
            if readOnly, !classified.isAllowedInReadOnly { throw .readOnly }          // DR-12, camada 1: antes do envio
            let rewritten: RewrittenStatement
            do {
                rewritten = try ParameterScanner.rewrite(statement, lexed: split.lexed, style: style)
            } catch {
                throw .validation(RedactedMessage(alreadyRedacted: "Não misture parâmetros :nome com ? ou $1 na mesma instrução."))
            }
            let bindings = rewritten.bindOrder.map { name -> BindValue in
                guard let value = parameters[name] else { missing.insert(name); return .null }
                return value
            }
            let range = (statement.range.lowerBound + offset)..<(statement.range.upperBound + offset)
            planned.append(PlannedStatement(statement: BoundStatement(sql: rewritten.sql, bindings: bindings),
                                            risk: classified.risk, sourceRange: range))
            classifiedAll.append(classified)
        }
        guard missing.isEmpty else {
            // Nomes de parâmetro não são segredo; valores nunca entram na mensagem.
            throw .validation(RedactedMessage(alreadyRedacted: "Informe valores para: " + missing.sorted().map { ":" + $0 }.joined(separator: ", ")))
        }
        return ExecutionPlan(statements: planned, classified: classifiedAll)
    }

    /// Nomes de parâmetro do escopo, para o formulário de valores (RF-QRY-11).
    public static func parameterNames(_ text: String, scope: ExecutionScope, dialect: SQLDialect) -> [String] {
        let split = StatementSplitter.split(text, dialect: dialect)
        let statements: [SQLStatement] = switch scope {
        case .all: split.statements
        case .current(let cursor): split.statement(atUTF16Offset: cursor).map { [$0] } ?? []
        case .selection(let range): split.statements(overlapping: range)
        }
        var seen: Set<String> = []
        return statements.flatMap { ParameterScanner.names(in: $0, lexed: split.lexed) }.filter { seen.insert($0).inserted }
    }

    /// Executa o plano na aba (uma execução por aba; para na primeira falha).
    public func run(_ plan: ExecutionPlan, session: DatabaseSession, tab: TabID, executionID: ExecutionID,
                    limits: ReadLimits = .default, confirmation: ConfirmationToken? = nil) async throws(RSKeeperError) -> ScriptOutcome {
        try await session.executeScript(plan.statements, tab: tab, executionID: executionID, limits: limits, confirmation: confirmation)
    }
}
