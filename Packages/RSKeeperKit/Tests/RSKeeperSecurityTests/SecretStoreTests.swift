import Foundation
import Testing
import RSKeeperDomain
@testable import RSKeeperSecurity

/// NT-SEC-02/03/04/15. Só o serviço `….test.secrets` é tocado; os de Dev e Produção são contados
/// antes e depois e nunca alterados.
@Suite("SecretStore — Keychain (NT-SEC-02/03/04/15)", .serialized)
struct SecretStoreTests {
    private let base = "app.rskeeper.RSKeeper"
    private var testService: String { SecretStore.service(bundleIDBase: base, environment: .test) }
    private var protectedServices: [String] {
        [SecretStore.service(bundleIDBase: base, environment: .prod), SecretStore.service(bundleIDBase: base, environment: .dev)]
    }

    private func serverProfile(host: String = "db.exemplo.invalid", port: UInt16 = 5432) -> ConnectionProfile {
        ConnectionProfile(name: "Teste", driverID: .postgresql, target: .server(host: host, port: port, user: "app", password: nil))
    }

    @Test("Serviço por ambiente")
    func servicePerEnvironment() {
        #expect(testService == "app.rskeeper.RSKeeper.test.secrets")
        #expect(protectedServices == ["app.rskeeper.RSKeeper.secrets", "app.rskeeper.RSKeeper.dev.secrets"])
    }

    @Test("Gravar, ler, substituir e apagar; serviços de Dev/Produção intocados (NT-SEC-15)")
    func roundTripWithoutTouchingOtherServices() async throws {
        let before = protectedServices.map(SecretStore.itemCount)
        let store = SecretStore(service: testService)
        let profile = serverProfile()
        let key = SecretKey(profileID: profile.id, purpose: .password)
        let print = TargetFingerprinter.fingerprint(of: profile)

        let ref = try await store.store("primeira-\(UUID().uuidString)", for: key, fingerprint: print)
        #expect(await store.hasSecret(for: key))
        _ = try await store.store("segunda", for: key, fingerprint: print)
        #expect(try await store.value(for: ref, currentFingerprint: print) == "segunda")
        try await store.delete(key)
        #expect(await store.hasSecret(for: key) == false)
        await #expect(throws: SecretStoreError.notFound) { _ = try await store.value(for: ref, currentFingerprint: print) }
        try await store.deleteAll(for: profile.id)
        #expect(protectedServices.map(SecretStore.itemCount) == before)
        #expect(SecretStore.itemCount(service: testService) == 0, "nenhuma sobra no serviço de teste")
    }

    @Test("NT-SEC-03: mudar host, porta, usuário ou SSH sem novo segredo invalida o segredo")
    func targetChangeInvalidatesSecret() async throws {
        let store = SecretStore(service: testService)
        var profile = serverProfile()
        let key = SecretKey(profileID: profile.id, purpose: .password)
        let ref = try await store.store("s3nh4", for: key, fingerprint: TargetFingerprinter.fingerprint(of: profile))

        for change in 0..<4 {
            var changed = profile
            switch change {
            case 0: changed.target = .server(host: "outro.exemplo.invalid", port: 5432, user: "app", password: nil)
            case 1: changed.target = .server(host: "db.exemplo.invalid", port: 6543, user: "app", password: nil)
            case 2: changed.target = .server(host: "db.exemplo.invalid", port: 5432, user: "root", password: nil)
            default: changed.ssh = SSHOptions(host: "bastion", user: "u", auth: .agent)
            }
            let newPrint = TargetFingerprinter.fingerprint(of: changed)
            #expect(newPrint != TargetFingerprinter.fingerprint(of: profile))
            await #expect(throws: SecretStoreError.invalidated) { _ = try await store.value(for: ref, currentFingerprint: newPrint) }
        }
        // Mudar só o nome ou a cor não invalida.
        profile.name = "Outro nome"
        profile.labelColor = .teal
        #expect(try await store.value(for: ref, currentFingerprint: TargetFingerprinter.fingerprint(of: profile)) == "s3nh4")
        try await store.deleteAll(for: profile.id)
    }

    @Test("NT-SEC-04: item não sincronizável, no serviço e na conta esperados; valor fora dos atributos")
    func itemAttributes() async throws {
        let store = SecretStore(service: testService)
        let profile = serverProfile()
        let key = SecretKey(profileID: profile.id, purpose: .sshPassword)
        _ = try await store.store("valor-secreto", for: key, fingerprint: TargetFingerprinter.fingerprint(of: profile))
        let attributes = await store.attributes(for: key)
        #expect(attributes[kSecAttrService as String] == testService)
        #expect(attributes[kSecAttrAccount as String] == "\(profile.id.raw.uuidString):sshPassword")
        #expect(attributes[kSecAttrSynchronizable as String].map { $0 == "0" || $0 == "false" } ?? true)
        #expect(!attributes.values.contains("valor-secreto"))
        try await store.deleteAll(for: profile.id)
    }

    @Test("NT-SEC-02: hasSecret informa existência sem expor o valor; referência .prompt nunca lê")
    func noValueExposure() async throws {
        let store = SecretStore(service: testService)
        let profile = serverProfile()
        await #expect(throws: SecretStoreError.notFound) {
            _ = try await store.value(for: .prompt, currentFingerprint: TargetFingerprinter.fingerprint(of: profile))
        }
        #expect(await store.hasSecret(for: SecretKey(profileID: profile.id, purpose: .password)) == false)
    }
}
