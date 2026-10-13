import RSKeeperDomain
import RSKeeperDriversCore

/// Registro imutável de drivers, montado na raiz de composição (docs/native/04 §3).
public struct DriverRegistry: Sendable {
    private let factories: [DriverID: any DriverFactory]

    public init(_ factories: [any DriverFactory]) {
        var map: [DriverID: any DriverFactory] = [:]
        for factory in factories { map[factory.descriptor.id] = factory }
        self.factories = map
    }

    public func factory(for id: DriverID) -> (any DriverFactory)? { factories[id] }
    public var descriptors: [DriverDescriptor] { factories.values.map(\.descriptor).sorted { $0.displayName < $1.displayName } }
}

/// Resolve o alvo de um perfil: acesso a arquivo (grant) e segredos do Keychain.
/// Implementações reais entram com SecretStore (W0-T24) e BookmarkStore (W0-T21).
public protocol TargetResolving: Sendable {
    func resolve(_ profile: ConnectionProfile) async throws(RSKeeperError) -> ResolvedTarget
}

/// Caso de uso "conectar" (NST-01-03). Sem UI; cancelável pela `Task` que o chama.
public struct ConnectUseCase: Sendable {
    private let drivers: DriverRegistry
    private let sessions: SessionRegistry
    private let resolver: any TargetResolving

    public init(drivers: DriverRegistry, sessions: SessionRegistry, resolver: any TargetResolving) {
        self.drivers = drivers
        self.sessions = sessions
        self.resolver = resolver
    }

    /// Valida o perfil, resolve o alvo e abre a sessão. Cancelar a `Task` cancela a abertura.
    public func connect(_ profile: ConnectionProfile, window: WindowID) async throws(RSKeeperError) -> SessionID {
        guard let factory = drivers.factory(for: profile.driverID) else {
            throw .unsupported(RedactedMessage(alreadyRedacted: "Driver não disponível: \(profile.driverID.rawValue)."))
        }
        do {
            try profile.validate(against: factory.descriptor.requirements)
            try factory.validate(profile.target)
        } catch let error as ProfileValidationError {
            throw .validation(RedactedMessage(alreadyRedacted: "Perfil inválido: \(error)."))
        } catch let error as DriverError {
            throw error.applicationError
        } catch {
            throw .internal(RedactedMessage(alreadyRedacted: "Falha inesperada na validação."))
        }
        if Task.isCancelled { throw .cancelled }
        let target = try await resolver.resolve(profile)
        let options = OpenOptions(readOnly: profile.readOnly, tls: profile.tls)
        return try await sessions.open(window: window, profileID: profile.id, factory: factory, target: target, options: options)
    }
}
