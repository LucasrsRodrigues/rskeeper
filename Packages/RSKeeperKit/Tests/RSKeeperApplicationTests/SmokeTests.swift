import Testing
import RSKeeperApplication

@Suite("RSKeeperApplication — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara as dependências do README §4")
    func moduleIsAvailable() {
        #expect(RSKeeperApplication.moduleName == "RSKeeperApplication")
        #expect(!RSKeeperApplication.dependsOn.isEmpty)
    }
}
