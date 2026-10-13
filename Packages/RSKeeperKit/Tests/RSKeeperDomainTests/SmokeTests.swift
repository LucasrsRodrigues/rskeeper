import Testing
@testable import RSKeeperDomain
import RSKeeperTesting

@Suite("RSKeeperDomain — fumaça")
struct SmokeTests {
    @Test("O módulo de domínio é importável e se identifica")
    func domainModuleIsAvailable() {
        #expect(RSKeeperDomain.moduleName == "RSKeeperDomain")
    }

    @Test("O módulo de testes é importável pelos alvos de teste")
    func testingModuleIsAvailable() {
        #expect(RSKeeperTesting.moduleName == "RSKeeperTesting")
    }
}
