import Foundation
import Testing
import RSKeeperDesignSystem

@Suite("RSKeeperDesignSystem — fumaça")
struct SmokeTests {
    @Test("O módulo não depende de outros módulos do RSKeeper")
    func moduleHasNoInternalDependencies() {
        #expect(RSKeeperDesignSystem.dependsOn.isEmpty)
    }

    @Test("Os recursos são processados e acessíveis por Bundle.module")
    func resourcesAreBundled() {
        let bundle = RSKeeperDesignSystem.resourceBundle
        #expect(bundle.bundleURL.lastPathComponent.hasSuffix(".bundle"))
        // O catálogo compilado (Assets.car) existe dentro do bundle de recursos.
        let car = bundle.url(forResource: "Assets", withExtension: "car")
        #expect(car != nil)
    }
}
