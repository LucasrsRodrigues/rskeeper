// RSKeeperDesignSystem — tokens, estilos e componentes básicos (SwiftUI e AppKit).
//
// Não depende de nenhum outro módulo do RSKeeper. Recursos (catálogos de cor) são
// processados pelo SwiftPM e acessados por `Bundle.module`.

import Foundation

/// Marcador do módulo `RSKeeperDesignSystem`.
public enum RSKeeperDesignSystem {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperDesignSystem"

    /// Módulos do RSKeeper dos quais este depende (README §4).
    public static let dependsOn: [String] = []

    /// Bundle de recursos do Design System.
    public static var resourceBundle: Bundle { .module }
}
