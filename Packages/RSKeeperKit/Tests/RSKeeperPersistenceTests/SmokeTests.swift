import Testing
import RSKeeperPersistence

@Suite("RSKeeperPersistence — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara as dependências do README §4")
    func moduleIsAvailable() {
        #expect(RSKeeperPersistence.moduleName == "RSKeeperPersistence")
        #expect(!RSKeeperPersistence.dependsOn.isEmpty)
    }
}
