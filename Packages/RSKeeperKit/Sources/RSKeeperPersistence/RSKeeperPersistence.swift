// RSKeeperPersistence — banco local, migrações e repositórios
//
// Marcador do módulo (Onda 0). Dependências permitidas: RSKeeperDomain, RSKeeperSecurity (tipos).

import RSKeeperDomain
import RSKeeperSecurity

/// Marcador do módulo `RSKeeperPersistence`.
public enum RSKeeperPersistence {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperPersistence"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperDomain", "RSKeeperSecurity"]
}
