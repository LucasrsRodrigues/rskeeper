// RSKeeperFeatures — telas e fluxos SwiftUI; nunca importa drivers, GRDB nem Security
//
// Marcador do módulo (Onda 0). Dependências permitidas: Application, DesignSystem, SQLEditor, DataGrid.

import RSKeeperApplication
import RSKeeperDesignSystem
import RSKeeperSQLEditor
import RSKeeperDataGrid

/// Marcador do módulo `RSKeeperFeatures`.
public enum RSKeeperFeatures {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperFeatures"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = ["RSKeeperApplication", "RSKeeperDesignSystem", "RSKeeperSQLEditor", "RSKeeperDataGrid"]
}
