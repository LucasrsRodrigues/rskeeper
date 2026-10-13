// RSKeeperDriversCore — protocolos de driver, capacidades e tipos de resultado
//
// Marcador do módulo (Onda 0). Dependências permitidas: RSKeeperDomain, RSKeeperSQLKit.

import RSKeeperDomain
import RSKeeperSQLKit

/// Marcador do módulo `RSKeeperDriversCore`.
public enum RSKeeperDriversCore {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperDriversCore"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperDomain", "RSKeeperSQLKit"]
}
