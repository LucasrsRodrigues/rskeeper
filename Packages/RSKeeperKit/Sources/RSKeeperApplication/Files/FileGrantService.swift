import Foundation
import RSKeeperDomain
import RSKeeperSecurity

/// Fronteira entre a UI e o acesso a arquivos (W0-T21). Features entrega a URL vinda do painel;
/// a aplicação a converte em concessão persistente. Features não importa RSKeeperSecurity.
public struct FileGrantService: Sendable {
    private let store: BookmarkStore

    public init(store: BookmarkStore) { self.store = store }

    /// Converte a URL escolhida pelo usuário num painel do sistema em `FileGrant`.
    public func grant(forUserSelected url: URL) async throws(RSKeeperError) -> FileGrant {
        do {
            return try await store.grant(forUserSelected: url)
        } catch FileGrantError.insideAppDataRoot {
            throw .permission(RedactedMessage(alreadyRedacted: "Arquivos internos do RSKeeper não podem ser abertos como conexão."))
        } catch {
            throw .permission(RedactedMessage(alreadyRedacted: "Não foi possível guardar o acesso ao arquivo."))
        }
    }

    /// Indica se uma URL externa pode ser aberta (só https: e mailto:).
    public static func canOpenExternally(_ url: URL) -> Bool { ExternalURLPolicy.isAllowed(url) }
}
