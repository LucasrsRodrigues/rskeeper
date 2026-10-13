import Testing
import RSKeeperDriversCore

@Suite("RSKeeperDriversCore — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara as dependências do README §4")
    func moduleIsAvailable() {
        #expect(RSKeeperDriversCore.moduleName == "RSKeeperDriversCore")
        #expect(!RSKeeperDriversCore.dependsOn.isEmpty)
    }
}
