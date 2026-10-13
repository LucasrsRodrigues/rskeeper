// RSKeeperDomain — tipos de valor do domínio do RSKeeper.
//
// Regras do módulo (docs/native/02):
// - sem I/O, sem actors, sem estado global mutável;
// - não importa SwiftUI nem AppKit;
// - não depende de nenhum outro módulo do RSKeeper.
//
// Os tipos de domínio entram na W0-T17. Este arquivo é apenas o marcador do módulo.

/// Marcador do módulo `RSKeeperDomain`.
public enum RSKeeperDomain {
    /// Nome do módulo, usado em testes de fumaça e diagnósticos.
    public static let moduleName = "RSKeeperDomain"
}
