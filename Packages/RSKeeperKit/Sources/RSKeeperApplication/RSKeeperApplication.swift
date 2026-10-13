// RSKeeperApplication — casos de uso, actors de sessão e estado observável
//
// Marcador do módulo (Onda 0). Dependências permitidas: Domain, SQLKit, DriversCore, Persistence, Security; nenhum driver concreto.

import RSKeeperDomain
import RSKeeperSQLKit
import RSKeeperDriversCore
import RSKeeperPersistence
import RSKeeperSecurity

/// Marcador do módulo `RSKeeperApplication`.
public enum RSKeeperApplication {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperApplication"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperDomain", "RSKeeperSQLKit", "RSKeeperDriversCore", "RSKeeperPersistence", "RSKeeperSecurity"]
}
