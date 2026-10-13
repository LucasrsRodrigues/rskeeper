import RSKeeperDomain
import RSKeeperDriversCore

/// Dono de um lease (docs/native/03 §11).
public enum LeaseOwner: Hashable, Sendable {
    case execution(ExecutionID)
    case transaction(TabID)
}

/// Posse **exclusiva** de uma conexão física durante uma execução (docs/native/03 §11; NT-CONC-02).
///
/// É não copiável: o compilador impede duplicar o lease ou usá-lo depois de devolvido.
/// A devolução é feita pelo `DatabaseSession`, dono do pool.
///
/// Decisão W0-D08: transações manuais guardam a conexão como referência dentro do actor
/// `DatabaseSession` (dicionários da stdlib não guardam valores `~Copyable`); o lease cobre
/// o escopo de cada execução.
public struct ConnectionLease: ~Copyable, Sendable {
    public let connection: any PhysicalConnection
    public let owner: LeaseOwner

    init(connection: any PhysicalConnection, owner: LeaseOwner) {
        self.connection = connection
        self.owner = owner
    }

    /// Consome o lease e devolve a conexão subjacente (uso interno do pool).
    consuming func take() -> any PhysicalConnection { connection }
}
