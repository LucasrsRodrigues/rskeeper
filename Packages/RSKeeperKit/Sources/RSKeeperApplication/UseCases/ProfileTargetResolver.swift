import Foundation
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperSecurity

/// Senhas digitadas para um único uso (perfil com "perguntar sempre", teste de conexão ou URL colada).
/// Consumidas na primeira resolução; nunca gravadas nem logadas (AR-IPC-08).
public actor TransientSecrets {
    private var values: [ProfileID: String] = [:]
    public init() {}
    public func deposit(_ value: String, for profile: ProfileID) { values[profile] = value }
    func take(_ profile: ProfileID) -> String? { values.removeValue(forKey: profile) }
    public func discard(_ profile: ProfileID) { values[profile] = nil }
}

/// Perfil → alvo que o driver abre (NST-03-03/05): bookmark → caminho com escopo de acesso; `SecretRef`
/// → senha do Keychain (verificando a impressão do alvo, NT-SEC-03) ou senha de uso único.
public struct ProfileTargetResolver: TargetResolving {
    private let bookmarks: BookmarkStore
    private let tracker: ScopedAccessTracker
    private let secrets: SecretStore
    private let transient: TransientSecrets

    public init(bookmarks: BookmarkStore, tracker: ScopedAccessTracker, secrets: SecretStore, transient: TransientSecrets) {
        self.bookmarks = bookmarks
        self.tracker = tracker
        self.secrets = secrets
        self.transient = transient
    }

    public func resolve(_ profile: ConnectionProfile) async throws(RSKeeperError) -> ResolvedTarget {
        switch profile.target {
        case .file(let grant, let openMode):
            do {
                let url = try await bookmarks.beginLongLivedAccess(to: grant, tracker: tracker)
                return .file(path: url.path, readOnly: openMode == .readOnly || profile.readOnly)
            } catch FileGrantError.staleOrInvalid, FileGrantError.unknownGrant {
                throw .permission(RedactedMessage(alreadyRedacted: "Não foi possível acessar o arquivo. Escolha-o de novo."))
            } catch {
                throw .permission(RedactedMessage(alreadyRedacted: "Arquivo não permitido."))
            }
        case .server(let host, let port, let user, let password):
            let secret: String?
            if let typed = await transient.take(profile.id) {
                secret = typed
            } else {
                switch password {
                case .stored?:
                    do {
                        secret = try await secrets.value(for: password!, currentFingerprint: TargetFingerprinter.fingerprint(of: profile))
                    } catch SecretStoreError.invalidated {
                        throw .auth(RedactedMessage(alreadyRedacted: "O alvo da conexão mudou: informe a senha de novo."))
                    } catch {
                        throw .auth(RedactedMessage(alreadyRedacted: "Senha salva não encontrada no Keychain."))
                    }
                case .prompt?:
                    throw .auth(RedactedMessage(alreadyRedacted: "Informe a senha para conectar."))
                case .missing?, nil:
                    secret = nil
                }
            }
            return .server(host: host, port: port, user: user, password: secret.map(SecretValue.init), database: profile.defaultDatabase)
        }
    }
}
