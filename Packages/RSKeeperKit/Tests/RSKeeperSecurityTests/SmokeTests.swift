import Testing
import RSKeeperSecurity

@Suite("RSKeeperSecurity — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara dependência só do domínio")
    func moduleIsAvailable() {
        #expect(RSKeeperSecurity.moduleName == "RSKeeperSecurity")
        #expect(RSKeeperSecurity.dependsOn == ["RSKeeperDomain"])
    }
}
