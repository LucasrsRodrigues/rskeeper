import Observation
import RSKeeperDomain

/// Estado observável de uma janela (docs/native/03 §10). Vive no MainActor e **nunca** faz I/O:
/// dispara `Task`s de casos de uso e aplica o resultado numa única atribuição.
@MainActor
@Observable
public final class WindowModel {
    public enum ConnectionStatus: Equatable, Sendable {
        case disconnected
        case connecting(ProfileID)
        case connected(SessionID, ProfileID)
        case failed(RSKeeperError)
    }

    public let windowID: WindowID
    public private(set) var status: ConnectionStatus = .disconnected
    /// Número de atualizações de estado aplicadas (auditável em teste: uma por transição).
    public private(set) var stateUpdates = 0

    @ObservationIgnored private let connectUseCase: ConnectUseCase
    @ObservationIgnored private let sessions: SessionRegistry
    @ObservationIgnored private var connectTask: Task<Void, Never>?

    public init(windowID: WindowID = .generate(), connectUseCase: ConnectUseCase, sessions: SessionRegistry) {
        self.windowID = windowID
        self.connectUseCase = connectUseCase
        self.sessions = sessions
    }

    /// Inicia a conexão. Uma conexão anterior em andamento é cancelada.
    public func connect(_ profile: ConnectionProfile) {
        connectTask?.cancel()
        apply(.connecting(profile.id))
        let useCase = connectUseCase
        let window = windowID
        connectTask = Task { [weak self] in
            let next: ConnectionStatus
            do throws(RSKeeperError) {
                let sessionID = try await useCase.connect(profile, window: window)
                next = .connected(sessionID, profile.id)
            } catch {
                next = error == .cancelled ? .disconnected : .failed(error)
            }
            guard !Task.isCancelled else { return }
            self?.apply(next)
        }
    }

    /// Cancela a conexão em andamento (cancelamento cooperativo até o driver).
    public func cancelConnect() {
        connectTask?.cancel()
        connectTask = nil
        apply(.disconnected)
    }

    /// Fecha as sessões da janela (cancelar → rollback → desconectar).
    public func closeWindow() async {
        connectTask?.cancel()
        await sessions.closeWindow(windowID)
        apply(.disconnected)
    }

    /// Aguarda a tarefa de conexão atual (para testes e encerramento ordenado).
    public func waitForConnection() async { await connectTask?.value }

    private func apply(_ next: ConnectionStatus) {
        guard next != status else { return }
        status = next
        stateUpdates += 1
    }
}

// MARK: Comandos (NST-13-01)

extension WindowModel: CommandPerforming {
    /// Contexto da janela para habilitar menus e atalhos. Abas, seleção e execução entram com as
    /// telas da onda 1 (W1-T17…T24); até lá, só o estado da conexão.
    public var commandContext: CommandContext {
        if case .connected = status { return CommandContext(isConnected: true) }
        return .none
    }

    public func perform(_ command: CommandID) {
        switch command {
        case CommandRegistry.disconnect:
            Task { await closeWindow() }
        default:
            break                                         // ainda sem ação nesta janela
        }
    }
}
