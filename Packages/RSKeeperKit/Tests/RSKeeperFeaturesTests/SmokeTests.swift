import Testing
import RSKeeperFeatures

@Suite("RSKeeperFeatures — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara as dependências do README §4")
    func moduleIsAvailable() {
        #expect(RSKeeperFeatures.moduleName == "RSKeeperFeatures")
        #expect(!RSKeeperFeatures.dependsOn.isEmpty)
    }
}
