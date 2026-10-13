import XCTest

/// XCUITest de fumaça (W0-T31; NT-SEC-14 em nível de app).
///
/// - O build Test exige `-RSKeeperDataRoot`; aqui é passado um NOME, criado no temporário do
///   próprio app (no sandbox, o `tmp` do container).
/// - A recusa sem o argumento (exit 78) é verificada por `scripts/ci/smoke-guard.sh`: o runner de
///   XCUITest não consegue executar o binário com sandbox como processo filho (SIGTRAP em
///   `_libsecinit_appsandbox`), e `XCUIApplication.launch()` não aceita um app que encerra ao iniciar.
@MainActor
final class LaunchTests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(language: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RSKeeperDataRoot", "uitest-\(UUID().uuidString)",
                               "-AppleLanguages", "(\(language))", "-AppleLocale", language.replacingOccurrences(of: "-", with: "_")]
        app.launch()
        return app
    }

    func testConnectionsWindowAppearsInEnglish() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Welcome to RSKeeper"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testConnectionsWindowAppearsInPortuguese() {
        let app = launch(language: "pt-BR")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Bem-vindo ao RSKeeper"].waitForExistence(timeout: 5))
        app.terminate()
    }

    func testDebugCommandOpensEmptyWorkspaceWindow() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open Empty Workspace Window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["rk.workspace.window"].waitForExistence(timeout: 10))
        app.terminate()
    }
}
