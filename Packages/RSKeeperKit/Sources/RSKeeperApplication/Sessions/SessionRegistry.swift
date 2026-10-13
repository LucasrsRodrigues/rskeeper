import RSKeeperDomain
import RSKeeperDriversCore

/// Registro de sessões do app, com escopo por janela (docs/native/03 §10; DR-06; NT-CONC-05).
///
/// Uma busca a partir de outra janela devolve `.notFound(.otherWindow)`, como se o recurso não existisse.
public actor SessionRegistry {
    /// Limites [META] do orçamento por sessão (DR-19) e da memória de IDs terminais (DR-06).
    public struct Limits: Sendable {
        public var maxConnectionsPerSession: Int
        public var finishedExecutionsRemembered: Int
        /// Validade do token de confirmação [META 60 s].
        public var confirmationLifetime: Duration = .seconds(60)

        public init(maxConnectionsPerSession: Int = 4, finishedExecutionsRemembered: Int = 1_000) {
            self.maxConnectionsPerSession = maxConnectionsPerSession
            self.finishedExecutionsRemembered = finishedExecutionsRemembered
        }
    }

    private let limits: Limits
    private var sessions: [SessionID: DatabaseSession] = [:]

    public init(limits: Limits = Limits()) { self.limits = limits }

    /// Abre uma sessão para a janela. Falha de conexão não deixa sessão registrada.
    /// `policy` é obrigatório: nenhum chamador pode esquecer o ambiente de produção (NST-07-04).
    public func open(window: WindowID, profileID: ProfileID, factory: any DriverFactory, target: ResolvedTarget,
                     options: OpenOptions = OpenOptions(), policy: OperationPolicyContext) async throws(RSKeeperError) -> SessionID {
        let id = SessionID.generate()
        let session = DatabaseSession(id: id, window: window, profileID: profileID, factory: factory, target: target,
                                      options: options, maxConnections: limits.maxConnectionsPerSession,
                                      finishedCapacity: limits.finishedExecutionsRemembered,
                                      policy: policy, confirmationLifetime: limits.confirmationLifetime)
        try await session.connect()
        sessions[id] = session
        return id
    }

    /// Sessão de uma janela. Outra janela recebe `.notFound(.otherWindow)`.
    public func session(_ id: SessionID, for window: WindowID) throws(RSKeeperError) -> DatabaseSession {
        guard let session = sessions[id] else { throw .notFound(.unknown) }
        guard session.window == window else { throw .notFound(.otherWindow) }
        return session
    }

    /// IDs das sessões de uma janela.
    public func sessions(of window: WindowID) -> [SessionID] {
        sessions.values.filter { $0.window == window }.map(\.id)
    }

    /// Fecha uma sessão específica.
    public func close(_ id: SessionID, for window: WindowID) async throws(RSKeeperError) {
        let session = try session(id, for: window)
        sessions[id] = nil
        await session.close()
    }

    /// Fecha todas as sessões da janela: cancelar → rollback → desconectar (NT-CONC-04).
    public func closeWindow(_ window: WindowID) async {
        let owned = sessions.values.filter { $0.window == window }
        for session in owned { sessions[session.id] = nil }
        for session in owned { await session.close() }
    }

    /// Fecha tudo (término do app).
    public func closeAll() async {
        let all = Array(sessions.values)
        sessions.removeAll()
        for session in all { await session.close() }
    }

    public var openSessionCount: Int { sessions.count }
}
