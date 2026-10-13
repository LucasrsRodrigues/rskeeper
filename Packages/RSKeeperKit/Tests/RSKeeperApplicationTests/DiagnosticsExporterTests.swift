import Foundation
import Testing
import RSKeeperDomain
@testable import RSKeeperApplication
import RSKeeperSecurity

@Suite("Diagnóstico — só metadados (W0-T15, NT-SEC-01)")
struct DiagnosticsExporterTests {
    private let canary = "canario-\(UUID().uuidString)"
    private let exporter = DiagnosticsExporter(context: .init(appVersion: "0.0.1", build: "1", environment: .test, sandboxed: true))

    @Test("Pacote contém versão, SO, arquitetura, ambiente e códigos de erro agregados")
    func containsMetadata() throws {
        let report = exporter.report(recentErrors: [.timeout, .timeout, .conflict(.busy)],
                                     operatingSystem: OperatingSystemVersion(majorVersion: 26, minorVersion: 6, patchVersion: 2),
                                     architecture: "arm64")
        #expect(report.osVersion == "26.6.2")
        #expect(report.environment == "test")
        #expect(report.recentErrorCodes == [.init(code: "conflict.busy", count: 1), .init(code: "timeout", count: 2)])
    }

    @Test("Canário (segredo, host, SQL, caminho) nunca entra no pacote")
    func canaryNeverExported() throws {
        let errors: [RSKeeperError] = [
            .connection(RedactedMessage(alreadyRedacted: "host db-\(canary).exemplo.invalid inacessível")),
            .driver(code: "42P01'; DROP \(canary)", message: RedactedMessage(alreadyRedacted: "SELECT * FROM \(canary)")),
            .validation(RedactedMessage(alreadyRedacted: "/Users/pessoa/\(canary).sqlite")),
            .auth(RedactedMessage(alreadyRedacted: "senha \(canary)")),
        ]
        let json = String(decoding: try exporter.export(recentErrors: errors), as: UTF8.self)
        #expect(!json.contains(canary))
        #expect(!json.contains("/Users/"))
        #expect(!json.contains("SELECT"))
        #expect(!json.contains("exemplo.invalid"))
        #expect(json.contains("\"driver.42P01DROPcanario"))   // só letras e dígitos, limitado a 16 caracteres
    }
}
