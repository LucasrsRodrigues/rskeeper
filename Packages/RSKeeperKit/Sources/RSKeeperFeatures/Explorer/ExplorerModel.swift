import Foundation
import Observation
import RSKeeperApplication
import RSKeeperDomain

/// Estado do explorador (NST-05-02): database → schema → entidades → colunas, carregados sob demanda.
@MainActor
@Observable
public final class ExplorerModel {
    /// Schemas de sistema ficam recolhidos por padrão [DECISÃO, NST-04-03 crit. 1].
    public static let systemSchemas: Set<String> = ["pg_catalog", "information_schema", "pg_toast", "temp"]

    public private(set) var database: String?
    public private(set) var schemas: [String] = []
    public private(set) var entities: [String: [ExplorerEntity]] = [:]
    public private(set) var columns: [String: [ExplorerColumn]] = [:]
    public var filter = ""
    public private(set) var isLoading = false
    public private(set) var error: String?
    /// Aumenta só em mudança estrutural (carga inicial, atualizar): a outline é reconstruída.
    public private(set) var revision = 0

    @ObservationIgnored private let service: ExplorerService
    @ObservationIgnored let onOpen: @MainActor (ExplorerEntity) -> Void

    public init(service: ExplorerService, onOpen: @escaping @MainActor (ExplorerEntity) -> Void) {
        self.service = service
        self.onOpen = onOpen
    }

    /// Carga inicial: database da conexão, schemas e as entidades dos schemas do usuário.
    public func load() async {
        isLoading = true
        defer { isLoading = false }
        do throws(RSKeeperError) {
            let database = try await service.currentDatabase()
            let names = try await service.schemas(in: database)
            self.database = database
            schemas = names.sorted { lhs, rhs in
                let (a, b) = (Self.systemSchemas.contains(lhs), Self.systemSchemas.contains(rhs))
                return a == b ? lhs.localizedStandardCompare(rhs) == .orderedAscending : !a
            }
            for schema in schemas where !Self.systemSchemas.contains(schema) { await loadEntities(schema) }
            error = nil
        } catch {
            self.error = error.description
        }
        revision += 1
    }

    public func refresh() async {
        await service.refresh()
        entities.removeAll()
        columns.removeAll()
        await load()
    }

    public func loadEntities(_ schema: String) async {
        guard entities[schema] == nil else { return }
        do throws(RSKeeperError) {
            entities[schema] = try await service.entities(database: database, schema: schema)
        } catch {
            self.error = error.description
            entities[schema] = []
        }
        // Sem `revision += 1`: a outline recarrega só o item expandido (reconstruir recolheria tudo).
    }

    public func loadColumns(_ entity: ExplorerEntity) async {
        guard columns[entity.id] == nil, entity.kind != .routine else { return }
        do throws(RSKeeperError) {
            columns[entity.id] = try await service.columns(of: entity)
        } catch {
            columns[entity.id] = []
        }
    }

    /// Entidades visíveis de um schema com o filtro (sem diferenciar maiúsculas e acentos).
    public func visibleEntities(_ schema: String) -> [ExplorerEntity] {
        let all = entities[schema] ?? []
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Schemas exibidos: com filtro, só os que têm entidade correspondente entre os carregados.
    public var visibleSchemas: [String] {
        filter.trimmingCharacters(in: .whitespaces).isEmpty ? schemas : schemas.filter { !visibleEntities($0).isEmpty }
    }

    /// Cabeçalho "ENTIDADES" com contador (CAP-04).
    public var entityCount: Int { visibleSchemas.reduce(0) { $0 + visibleEntities($1).count } }

    public func open(_ entity: ExplorerEntity) {
        guard entity.kind != .routine else { return }
        onOpen(entity)
    }
}
