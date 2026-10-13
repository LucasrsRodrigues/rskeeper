// RSKeeperSecurity — Keychain, security-scoped bookmarks, redação e logging.
//
// Regras do módulo (docs/native/02):
// - depende só de RSKeeperDomain (e de frameworks do sistema);
// - segredos nunca saem deste módulo em direção à UI.
//
// `SecretStore` (W0-T24), `Redactor`/logger (W0-T14) e bookmarks (W0-T21) entram
// nas tarefas correspondentes. Este arquivo é o marcador.

import RSKeeperDomain

/// Marcador do módulo `RSKeeperSecurity`.
public enum RSKeeperSecurity {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperSecurity"

    /// Módulo de domínio do qual este módulo depende (README §4).
    public static let dependsOn = [RSKeeperDomain.moduleName]
}
