// RSKeeperDataGrid — grade de dados (vazio na Onda 0, E-1)
//
// Marcador do módulo (Onda 0). Dependências permitidas: RSKeeperDesignSystem, RSKeeperDomain.

import RSKeeperDesignSystem
import RSKeeperDomain

/// Marcador do módulo `RSKeeperDataGrid`.
public enum RSKeeperDataGrid {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperDataGrid"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperDesignSystem", "RSKeeperDomain"]
}
