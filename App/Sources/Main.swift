/// Ponto de entrada. A **primeira instrução** é a guarda de ambiente (W0-T12, aceite 3):
/// nenhuma cena, dado ou log é tocado antes de a raiz de dados ser resolvida e validada.
@main
enum RSKeeperMain {
    static func main() {
        _ = EnvironmentGuard.environment
        RSKeeperApp.main()
    }
}
