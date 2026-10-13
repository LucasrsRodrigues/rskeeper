import Testing
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperTesting

/// NST-04-01 — a suíte de conformidade aplicada ao driver em memória (W1-T02).
/// Os drivers SQLite e PostgreSQL rodam a mesma suíte, com todas as verificações obrigatórias.
@Suite("Conformidade — driver em memória (W1-T02)")
struct InMemoryConformanceTests {
    private static let table = EntityRef(schema: SchemaRef(database: "memoria", name: "public"), name: "pedidos")

    private static func fixture() -> ConformanceFixture {
        let columns = [ResultColumn(name: "id", nativeTypeName: "int8", portableType: .bigint),
                       ResultColumn(name: "nome", nativeTypeName: "text", portableType: .text)]
        var generated: [String: RowGenerator] = [:]
        for n in [100_000, 200_000, 1_000_000, 5_000_000] {
            generated["GEN \(n)"] = RowGenerator(columns: columns, rowCount: n) { row, column in
                column == 0 ? .int(Int64(row)) : .text("linha \(row)")
            }
        }
        let catalog = InMemoryCatalog(
            entities: [table.schema: [EntityInfo(ref: table, kind: .table)]],
            columns: [table: [ColumnInfo(name: "id", ordinal: 1, declaredType: "int8", portableType: .bigint, nullable: false, isPrimaryKey: true),
                              ColumnInfo(name: "nome", ordinal: 2, declaredType: "text", portableType: .text, nullable: true, isPrimaryKey: false)]])
        let one = StatementOutcome.rows(columns: [ResultColumn(name: "?column?", nativeTypeName: "int4", portableType: .int)],
                                        firstBatch: RowBatch(columns: [[.int(1)]]), truncated: nil, rowCount: 1)
        let script = InMemoryDriver.Script(
            responses: ["SELECT 1": one], generated: generated,
            failures: ["SELEC 'segredo-xyz'": .syntaxOrSemantic(RedactedMessage(alreadyRedacted: "Erro de sintaxe."), position: 1)],
            catalog: catalog, slow: ["SLOW": .seconds(30)])
        return ConformanceFixture(
            factory: InMemoryDriver(script: script),
            target: .server(host: "memoria", port: 1, user: nil, password: nil, database: "memoria"),
            longRunning: "SLOW", generateRows: { "GEN \($0)" },
            invalidSQL: "SELEC 'segredo-xyz'", secretMarker: "segredo-xyz",
            expectedTable: (table, ["id", "nome"]))
    }

    /// Verificações que o driver em memória precisa passar; as demais exigem SQL real.
    private static let required: [ConformanceCheck] = [
        .openClose, .metadata, .cancelLongQuery, .truncationRows, .truncationBytes,
        .usableAfterTruncationAndCancel, .errorsNormalized, .capabilitiesCoherent,
    ]

    @Test("Verificação obrigatória passa", arguments: required)
    func requiredCheck(_ check: ConformanceCheck) async {
        let result = await DriverConformance.run(check, Self.fixture())
        #expect(result == .passed, "\(check.rawValue): \(result)")
    }

    @Test("Verificações que exigem SQL real são puladas com motivo (nunca aprovadas em silêncio)",
          arguments: ConformanceCheck.allCases.filter { !required.contains($0) })
    func skippedCheck(_ check: ConformanceCheck) async {
        let result = await DriverConformance.run(check, Self.fixture())
        guard case .skipped(let reason) = result else { Issue.record("\(check.rawValue): \(result)"); return }
        #expect(!reason.isEmpty)
    }

    @Test("A suíte detecta um driver não conforme (sensibilidade)")
    func detectsNonConformingDriver() async {
        // Mesmo driver, mas o SQL inválido "funciona": NT-DRV-20 precisa falhar.
        var fixture = Self.fixture()
        fixture.invalidSQL = "SELECT 1"
        guard case .failed = await DriverConformance.run(.errorsNormalized, fixture) else {
            Issue.record("a suíte aprovou um driver que aceitou SQL inválido"); return
        }
        // Capacidades incoerentes: .interrupt num driver de servidor.
        struct Incoherent: DriverFactory {
            let descriptor = DriverDescriptor(id: DriverID(rawValue: "x"), displayName: "x", targetKind: .server,
                                              capabilities: DriverCapabilities(cancel: .interrupt, explainAnalyze: true),
                                              dialect: ANSIDialect())
            func validate(_ target: ConnectionTarget) throws(DriverError) {}
            func open(_ target: ResolvedTarget, options: OpenOptions) async throws(DriverError) -> any PhysicalConnection { throw .unsupported(.cancel) }
        }
        fixture.factory = Incoherent()
        guard case .failed(let problems) = await DriverConformance.run(.capabilitiesCoherent, fixture) else {
            Issue.record("capacidades incoerentes aprovadas"); return
        }
        #expect(problems.count == 2)
    }

    @Test("Acumulador: linha maxRows+1 trunca sem ser guardada; teto de bytes")
    func accumulator() {
        var rows = BatchAccumulator(columnCount: 1, limits: ReadLimits(maxRows: 3, maxBytes: 1 << 20, maxCellBytes: 1024), batchSize: 2)
        for i in 0..<3 { #expect(rows.append([.int(Int64(i))]) == .continue) }
        #expect(rows.append([.int(9)]) == .stop)
        #expect(rows.end == .rows(truncated: .maxRows(3), rowCount: 3))

        var bytes = BatchAccumulator(columnCount: 1, limits: ReadLimits(maxRows: 100, maxBytes: 10, maxCellBytes: 1024), batchSize: 10)
        #expect(bytes.append([.text("12345")]) == .continue)
        #expect(bytes.append([.text("12345")]) == .continue)
        #expect(bytes.append([.text("x")]) == .stop)
        #expect(bytes.end == .rows(truncated: .maxBytes(10), rowCount: 2))
        #expect(bytes.takeBatch()?.rowCount == 2)
        #expect(bytes.takeBatch() == nil)
    }
}
