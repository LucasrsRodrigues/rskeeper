import Foundation
import RSKeeperDomain
import Security

/// Erros do Keychain (OSStatus preservado para diagnóstico; nunca o valor do segredo).
public enum SecretStoreError: Error, Equatable, Sendable {
    case notFound
    case invalidated
    case keychain(status: Int32)
}

/// Segredos no Keychain (W0-T24; ADR-N06; SPK-N07).
///
/// - Keychain **baseado em arquivo** (`kSecUseDataProtectionKeychain = false`): o data protection keychain
///   exige provisioning profile (SPK-N07: -34018 com assinatura ad hoc, com e sem sandbox).
/// - Serviço por ambiente: `<bundle id do ambiente>.secrets` (`…RSKeeper.secrets`, `….dev.secrets`,
///   `….test.secrets`). Conta = `<UUID do perfil>:<finalidade>`.
/// - Atributos: `WhenUnlockedThisDeviceOnly`, não sincronizável.
/// - O valor só sai daqui para a abertura da conexão; nunca para a UI.
public actor SecretStore {
    public nonisolated let service: String

    public init(service: String) { self.service = service }

    /// Serviço do ambiente a partir do bundle ID base.
    public static func service(bundleIDBase: String, environment: AppEnvironmentKind) -> String {
        bundleIDBase + environment.bundleIDSuffix + ".secrets"
    }

    /// Grava (ou substitui) o segredo e devolve a referência vinculada à impressão do alvo (DR-01).
    public func store(_ value: String, for key: SecretKey, fingerprint: TargetFingerprint) throws -> SecretRef {
        let account = Self.account(for: key)
        let data = Data(value.utf8)
        SecItemDelete(baseQuery(account: account) as CFDictionary)
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        attributes[kSecAttrLabel as String] = "RSKeeper — \(key.purpose.rawValue)"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw SecretStoreError.keychain(status: status) }
        return .stored(key, fingerprint: fingerprint)
    }

    /// Lê o segredo para abrir a conexão. Recusa se a impressão do alvo mudou (inv. 2.1-7).
    public func value(for reference: SecretRef, currentFingerprint: TargetFingerprint) throws -> String {
        guard case .stored(let key, let fingerprint) = reference else { throw SecretStoreError.notFound }
        guard fingerprint == currentFingerprint else { throw SecretStoreError.invalidated }
        var query = baseQuery(account: Self.account(for: key))
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status != errSecItemNotFound else { throw SecretStoreError.notFound }
        guard status == errSecSuccess, let data = result as? Data else { throw SecretStoreError.keychain(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Indica se existe segredo salvo (a UI mostra "senha salva" sem receber o valor; NT-SEC-02).
    public func hasSecret(for key: SecretKey) -> Bool {
        var query = baseQuery(account: Self.account(for: key))
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Remove um segredo (exclusão de perfil, troca para "perguntar").
    public func delete(_ key: SecretKey) throws {
        let status = SecItemDelete(baseQuery(account: Self.account(for: key)) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError.keychain(status: status) }
    }

    /// Remove todos os segredos de um perfil.
    public func deleteAll(for profileID: ProfileID) throws {
        for purpose in SecretPurpose.allCases { try delete(SecretKey(profileID: profileID, purpose: purpose)) }
    }

    /// Atributos do item (para o NT-SEC-04). Nunca inclui o valor.
    public func attributes(for key: SecretKey) -> [String: String] {
        var query = baseQuery(account: Self.account(for: key))
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let dict = result as? [String: Any] else { return [:] }
        var output: [String: String] = [:]
        for (name, value) in dict where name != (kSecValueData as String) { output[name] = "\(value)" }
        return output
    }

    /// Quantos itens existem num serviço (para provar que testes não tocam outros ambientes; NT-SEC-15).
    public static func itemCount(service: String) -> Int {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecUseDataProtectionKeychain as String: false,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return 0 }
        return (result as? [[String: Any]])?.count ?? 0
    }

    static func account(for key: SecretKey) -> String { "\(key.profileID.raw.uuidString):\(key.purpose.rawValue)" }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
