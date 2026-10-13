// RSKeeperSQLEditor — editor SQL (vazio na Onda 0, E-1)
//
// Marcador do módulo (Onda 0). Dependências permitidas: RSKeeperDesignSystem, RSKeeperSQLKit.

import RSKeeperDesignSystem
import RSKeeperSQLKit

/// Marcador do módulo `RSKeeperSQLEditor`.
public enum RSKeeperSQLEditor {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperSQLEditor"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperDesignSystem", "RSKeeperSQLKit"]
}
