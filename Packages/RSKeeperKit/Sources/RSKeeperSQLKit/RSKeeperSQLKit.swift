// RSKeeperSQLKit — processamento de SQL independente de UI e de driver.
//
// Regras do módulo (docs/native/02):
// - depende só de RSKeeperDomain;
// - funções puras e tipos `Sendable`; sem I/O;
// - não importa SwiftUI, AppKit nem drivers.
//
// NST-04-05 (W1-T01): Lexer/, Splitter/, Classifier/, Parameters/ e URL/.
// Quoting de identificadores fica com o `Dialect` de cada driver.

import RSKeeperDomain

/// Marcador do módulo `RSKeeperSQLKit`.
public enum RSKeeperSQLKit {
    /// Nome do módulo, usado em testes de fumaça.
    public static let moduleName = "RSKeeperSQLKit"

    /// Módulo de domínio do qual este módulo depende (README §4).
    public static let dependsOn = [RSKeeperDomain.moduleName]
}
