import Testing
import RSKeeperSQLKit

@Suite("RSKeeperSQLKit — fumaça")
struct SmokeTests {
    @Test("O módulo é importável e declara dependência só do domínio")
    func moduleIsAvailable() {
        #expect(RSKeeperSQLKit.moduleName == "RSKeeperSQLKit")
        #expect(RSKeeperSQLKit.dependsOn == ["RSKeeperDomain"])
    }
}
