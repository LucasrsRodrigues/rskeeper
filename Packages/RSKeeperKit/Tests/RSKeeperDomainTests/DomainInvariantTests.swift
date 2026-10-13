import Foundation
import Testing
@testable import RSKeeperDomain

/// NT-UNIT-01 — invariantes dos tipos de domínio (W0-T17).
@Suite("Domínio — invariantes (NT-UNIT-01)")
struct DomainInvariantTests {
    private let server = DriverRequirements(targetKind: .server, supportsTLS: true, supportsSSH: true)
    private let sqlite = DriverRequirements(targetKind: .file, supportsTLS: false, supportsSSH: false)
    private let grant = FileGrant(id: UUID(), displayPath: "/tmp/sintetico.sqlite")

    private func serverProfile(password: SecretRef? = nil, savePasswords: Bool = true) -> ConnectionProfile {
        ConnectionProfile(name: "Local PG", driverID: .postgresql,
                          target: .server(host: "localhost", port: 5432, user: "app", password: password),
                          savePasswords: savePasswords)
    }

    // MARK: IDs

    @Test("IDs gerados são UUIDv7 e ordenáveis pelo instante")
    func idsAreUUIDv7() {
        let early = UUIDv7.generate(now: Date(timeIntervalSince1970: 1_000))
        let late = UUIDv7.generate(now: Date(timeIntervalSince1970: 2_000))
        #expect(UUIDv7.version(of: early) == 7)
        #expect(UUIDv7.timestampMillis(of: early) == 1_000_000)
        #expect(UUIDv7.timestampMillis(of: late) > UUIDv7.timestampMillis(of: early))
        #expect(UUIDv7.version(of: ProfileID.generate().raw) == 7)
    }

    @Test("Variante RFC é aplicada ao UUIDv7")
    func uuidv7Variant() {
        let uuid = UUIDv7.generate(randomBytes: { Array(repeating: 0xFF, count: 10) })
        #expect(uuid.uuid.8 & 0xC0 == 0x80)
        #expect(uuid.uuid.6 & 0xF0 == 0x70)
    }

    @Test("IDs tipados fazem ida e volta em JSON como UUID simples")
    func typedIDCodable() throws {
        let id = TabID.generate()
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(TabID.self, from: data) == id)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(id.raw.uuidString)\"")
    }

    // MARK: ConnectionProfile (03 §2.1)

    @Test("Inv. 1: o tipo de alvo coincide com o driver")
    func targetKindMustMatchDriver() {
        let profile = serverProfile()
        #expect(throws: ProfileValidationError.targetKindMismatch(expected: .file, actual: .server)) {
            try profile.validate(against: sqlite)
        }
        #expect(throws: Never.self) { try profile.validate(against: server) }
    }

    @Test("Inv. 2: TLS e SSH exigem capacidade; SSH exige alvo servidor")
    func tlsAndSSHRequireCapability() {
        var profile = ConnectionProfile(name: "Arquivo", driverID: .sqlite, target: .file(grant, openMode: .readWrite))
        profile.tls = TLSOptions(mode: .require)
        #expect(throws: ProfileValidationError.tlsNotSupported) { try profile.validate(against: sqlite) }
        profile.tls = nil
        profile.ssh = SSHOptions(host: "bastion", user: "u", auth: .agent)
        #expect(throws: ProfileValidationError.sshNotSupported) { try profile.validate(against: sqlite) }
        let permissive = DriverRequirements(targetKind: .file, supportsTLS: true, supportsSSH: true)
        #expect(throws: ProfileValidationError.sshRequiresServerTarget) { try profile.validate(against: permissive) }
    }

    @Test("Inv. 3: porta zero é inválida")
    func portZeroIsInvalid() {
        let profile = ConnectionProfile(name: "x", driverID: .postgresql,
                                        target: .server(host: "h", port: 0, user: nil, password: nil))
        #expect(throws: ProfileValidationError.invalidPort) { try profile.validate(against: server) }
    }

    @Test("Inv. 5: sem salvar senhas, nenhum segredo fica armazenado")
    func storedSecretRequiresSavePasswords() {
        let key = SecretKey(profileID: .generate(), purpose: .password)
        let stored = SecretRef.stored(key, fingerprint: TargetFingerprint(digest: [1]))
        #expect(throws: ProfileValidationError.storedSecretWithoutSavePasswords) {
            try serverProfile(password: stored, savePasswords: false).validate(against: server)
        }
        #expect(throws: Never.self) { try serverProfile(password: .prompt, savePasswords: false).validate(against: server) }
    }

    @Test("Inv. 6: nome não vazio num perfil salvo; unicidade sem distinguir maiúsculas")
    func nameRules() {
        var profile = serverProfile()
        profile.name = "   "
        #expect(throws: ProfileValidationError.emptyName) { try profile.validate(against: server) }
        profile.isDraft = true
        #expect(throws: Never.self) { try profile.validate(against: server) }
        let a = ConnectionProfile(name: " Produção ", driverID: .mysql, target: .server(host: "h", port: 3306, user: nil, password: nil))
        let b = ConnectionProfile(name: "produção", driverID: .mysql, target: .server(host: "h", port: 3306, user: nil, password: nil))
        #expect(a.uniquenessKey == b.uniquenessKey)
    }

    @Test("Inv. 7: trocar o alvo sem novo segredo invalida os segredos armazenados (DR-01)")
    func secretBoundToTargetFingerprint() {
        let oldPrint = TargetFingerprint(digest: [0xAA])
        let newPrint = TargetFingerprint(digest: [0xBB])
        let key = SecretKey(profileID: .generate(), purpose: .password)
        var profile = serverProfile(password: .stored(key, fingerprint: oldPrint))
        profile.ssh = SSHOptions(host: "b", user: "u",
                                 auth: .password(.stored(SecretKey(profileID: key.profileID, purpose: .sshPassword), fingerprint: oldPrint)))
        let invalidated = profile.invalidatingSecrets(notMatching: newPrint)
        #expect(invalidated.allSecretRefs == [.missing, .missing])
        let kept = profile.invalidatingSecrets(notMatching: oldPrint)
        #expect(kept.allSecretRefs == profile.allSecretRefs)
    }

    // MARK: EnvironmentKind (03 §18.1)

    @Test("Sugestão de ambiente: arquivo e localhost → local; remoto → development")
    func environmentSuggestion() {
        #expect(EnvironmentKind.suggested(for: .file(grant, openMode: .readOnly)) == .local)
        #expect(EnvironmentKind.suggested(for: .server(host: "LOCALHOST", port: 1, user: nil, password: nil)) == .local)
        #expect(EnvironmentKind.suggested(for: .server(host: "db.exemplo.invalid", port: 1, user: nil, password: nil)) == .development)
        #expect(serverProfile().environment == .local)
    }

    @Test("Migração de ProfileEnvironment: unspecified → development não confirmado")
    func environmentMigration() {
        #expect(EnvironmentKind.migrated(fromLegacy: "unspecified") == (.development, false))
        #expect(EnvironmentKind.migrated(fromLegacy: "production") == (.production, true))
        #expect(EnvironmentKind.migrated(fromLegacy: "staging") == (.staging, true))
    }

    // MARK: CellValue (NST-01-01 crit. 3)

    @Test("Inteiros fora de Int64 e decimais preservam o texto exato")
    func exactNumericText() {
        #expect(CellValue.integerText("42") == .int(42))
        #expect(CellValue.integerText("92233720368547758070") == .decimal("92233720368547758070"))
    }

    @Test("Binários guardam prévia ≤ 4 KiB e o tamanho total")
    func binaryPreview() {
        let value = CellValue.binary(Array(repeating: 7, count: 10_000))
        guard case .bytes(let preview, let total) = value else { Issue.record("esperado .bytes"); return }
        #expect(preview.count == CellValueLimits.bytesPreviewMax)
        #expect(total == 10_000)
    }

    @Test("Texto acima de 64 KiB vira .truncated sem cortar caractere multibyte")
    func textTruncation() {
        let big = String(repeating: "é", count: 40_000) // 80 000 bytes UTF-8
        guard case .truncated(let prefix, let total) = CellValue.textValue(big) else { Issue.record("esperado .truncated"); return }
        #expect(total == 80_000)
        #expect(prefix.utf8.count <= CellValueLimits.inlineTextMax)
        #expect(prefix.allSatisfy { $0 == "é" })
        #expect(CellValue.textValue("curto") == .text("curto"))
    }

    // MARK: Erros

    @Test("Erros carregam só mensagens redigidas e não sugerem retry de escrita")
    func errorsAreRedactedAndExplicit() {
        let error = RSKeeperError.driver(code: "42P01", message: RedactedMessage(alreadyRedacted: "relação inexistente"))
        #expect(error.description == "driver[42P01]: relação inexistente")
        #expect(RSKeeperError.outcomeUnknown(.connectionLost).isTransientForIdempotentRead == false)
        #expect(RSKeeperError.connection(RedactedMessage(alreadyRedacted: "x")).isTransientForIdempotentRead)
    }
}

/// NT-UNIT-11 (parcial na Onda 0) — estados de execução.
@Suite("Domínio — estados de execução (NT-UNIT-11, parcial)")
struct ExecutionStateTests {
    @Test("Estados terminais não mudam; não existe fila")
    func terminalStatesAreFinal() {
        let finished = ExecutionState.finished(.succeeded)
        #expect(finished.isTerminal)
        #expect(!finished.canTransition(to: .running(statementIndex: 0)))
        #expect(!finished.canTransition(to: .cancelling))
    }

    @Test("Running avança por índice, pode cancelar e terminar")
    func runningTransitions() {
        let running = ExecutionState.running(statementIndex: 1)
        #expect(running.canTransition(to: .running(statementIndex: 2)))
        #expect(!running.canTransition(to: .running(statementIndex: 1)))
        #expect(running.canTransition(to: .cancelling))
        #expect(ExecutionState.cancelling.canTransition(to: .finished(.cancelled)))
        #expect(!ExecutionState.cancelling.canTransition(to: .running(statementIndex: 3)))
    }

    @Test("O script para na primeira falha (DR-13)")
    func stopAtFirstFailure() {
        let failure = RSKeeperError.driver(code: "1", message: RedactedMessage(alreadyRedacted: "falha"))
        let valid = [
            StatementReport(index: 0, risk: .write, status: .ok, committed: .yes),
            StatementReport(index: 1, risk: .write, status: .failed(failure), committed: .no),
            StatementReport(index: 2, risk: .read, status: .skipped, committed: .no),
        ]
        #expect(StatementReport.stopAtFirstFailure(valid))
        var invalid = valid
        invalid[2] = StatementReport(index: 2, risk: .read, status: .ok, committed: .no)
        #expect(!StatementReport.stopAtFirstFailure(invalid))
    }
}
