import Foundation
import os
import OSLog
import Synchronization
import Testing
@testable import RSKeeperSecurity

private final class CapturingSink: LogSink {
    private let lines = Mutex<[String]>([])
    func write(level: OSLogType, category: String, event: String, rendered: String) {
        lines.withLock { $0.append(rendered) }
    }
    var captured: [String] { lines.withLock { $0 } }
}

/// NT-UNIT-12 — redação; NT-SEC-01 (canário no nível do logger).
@Suite("Logging e redação (NT-UNIT-12, NT-SEC-01)")
struct LoggingTests {
    private let canary = "canario-\(UUID().uuidString)"

    @Test("Redige senhas, passphrases, tokens e URLs com credencial")
    func redactsCommonSecrets() {
        let redactor = Redactor()
        let samples: [(String, String)] = [
            ("password=hunter2 host=db", "hunter2"),
            ("PWD: 'pa ss'", "pa ss"),
            ("passphrase=\"chave secreta\"", "chave secreta"),
            ("token=abc.def.ghi", "abc.def.ghi"),
            ("api_key=K123456", "K123456"),
            ("postgres://admin:s3nh4@db.exemplo.invalid:5432/app", "s3nh4"),
            ("Authorization: Bearer eyJhbGciOi.xyz", "eyJhbGciOi.xyz"),
            ("ALTER USER app IDENTIFIED BY 'trocar123'", "trocar123"),
        ]
        for (input, secret) in samples {
            let output = redactor.redact(input)
            #expect(!output.contains(secret), "vazou em: \(output)")
            #expect(output.contains(Redactor.mask))
        }
        #expect(redactor.redact("postgres://admin:s3nh4@h/app").contains("postgres://admin:"))
        #expect(redactor.redact("SELECT 1") == "SELECT 1")
    }

    @Test("Segredos conhecidos (canário) são mascarados em qualquer posição")
    func redactsKnownSecrets() {
        let redactor = Redactor(knownSecrets: [canary])
        #expect(!redactor.redact("erro ao conectar com \(canary) no meio").contains(canary))
        #expect(!redactor.message("x\(canary)y").text.contains(canary))
    }

    @Test("Canário não aparece no que o logger emite; campos privados ficam <private>")
    func canaryAbsentFromLoggerOutput() {
        let sink = CapturingSink()
        let logger = RKLogger(subsystem: "app.rskeeper.RSKeeper.test", category: "tests",
                              redactor: Redactor(knownSecrets: [canary]), sink: sink)
        logger.info("connect.failed", ["code": .public("28P01"), "detail": .private("senha \(canary) recusada")])
        logger.error("query.failed", ["sql": .query("SELECT * FROM t WHERE pwd = '\(canary)'"), "pwd": .public(canary)])
        let output = sink.captured.joined(separator: "\n")
        #expect(!output.contains(canary), "canário vazou: \(output)")
        #expect(output.contains("code=28P01"))
        #expect(output.contains("<private>"))
    }

    @Test("NT-SEC-01: canário ausente do Unified Logging real (OSLogStore do processo)")
    func canaryAbsentFromUnifiedLog() throws {
        let subsystem = "app.rskeeper.RSKeeper.test.nt-sec-01.\(UUID().uuidString.prefix(8))"
        let logger = RKLogger(subsystem: subsystem, category: "canary", redactor: Redactor(knownSecrets: [canary]))
        let start = Date()
        logger.notice("canary.emit", ["detail": .private("valor \(canary)"), "shown": .public("password=\(canary)")])
        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)))
            .compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == subsystem }
        #expect(!entries.isEmpty, "a entrada de log deveria existir")
        for entry in entries {
            #expect(!entry.composedMessage.contains(canary), "canário no OSLog: \(entry.composedMessage)")
        }
    }

    @Test("Subsistema por ambiente")
    func subsystemPerEnvironment() {
        #expect(RKLogger.subsystem(bundleIDBase: "app.rskeeper.RSKeeper", environment: .dev) == "app.rskeeper.RSKeeper.dev")
        #expect(RKLogger.subsystem(bundleIDBase: "app.rskeeper.RSKeeper", environment: .test) == "app.rskeeper.RSKeeper.test")
        #expect(RKLogger.subsystem(bundleIDBase: "app.rskeeper.RSKeeper", environment: .prod) == "app.rskeeper.RSKeeper")
    }

    @Test("Nenhum código do pacote apaga logs (aceite 5)")
    func noCodeDeletesLogs() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        var offenders: [String] = []
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            if text.range(of: #"Library/Logs|OSLogStore|\.log"\)|removeItem\(at: .*[Ll]og"#, options: .regularExpression) != nil {
                offenders.append(url.lastPathComponent)
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
