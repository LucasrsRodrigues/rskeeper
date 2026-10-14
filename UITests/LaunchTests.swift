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
        app.launchArguments = ["-RSKeeperDataRoot", "uitest-\(UUID().uuidString)", "-ApplePersistenceIgnoreState", "YES",
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

    /// NST-13-01, crit. 1: sem conexão, comandos de conexão e de consulta ficam desabilitados.
    func testConnectionCommandsDisabledWithoutConnection() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Query"].click()
        XCTAssertTrue(app.menuItems["Run All"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.menuItems["Run All"].isEnabled)
        XCTAssertFalse(app.menuItems["Cancel Execution"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Disconnect"].isEnabled)
        XCTAssertTrue(app.menuItems["New Connection…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    /// NST-03-01…05: nova conexão → seletor de driver → formulário SQLite → testar → conectar → workspace
    /// com o título da conexão; a conexão aparece em "Recentes".
    func testCreateTestAndConnectSQLite() {
        let app = launch(language: "en")
        XCTAssertTrue(app.buttons["rk.connections.new"].waitForExistence(timeout: 10))
        app.buttons["rk.connections.new"].click()
        let sqlite = app.descendants(matching: .any)["rk.driverPicker.item.sqlite"].firstMatch
        XCTAssertTrue(sqlite.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["rk.driverPicker.next"].isEnabled, "Avançar só com seleção (CAP-03)")
        sqlite.click()
        app.buttons["rk.driverPicker.next"].click()
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Use Sample Database File"].click()
        let name = app.textFields["rk.connections.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Amostra UI")
        app.buttons["rk.connections.form.test"].click()
        let result = app.descendants(matching: .any)["rk.connections.form.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'SQLite'")).firstMatch.exists
                      || result.label.contains("SQLite"))
        app.buttons["rk.connections.form.connect"].click()
        XCTAssertTrue(app.windows["Amostra UI"].waitForExistence(timeout: 10), "o título da janela identifica a conexão")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.row.Amostra UI"].firstMatch.waitForExistence(timeout: 5))
        app.terminate()
    }

    /// NST-05-01: shell de quatro regiões; o menu Visualizar mostra/oculta sidebar e inspetor.
    func testWorkspaceShellTogglesRegions() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].firstMatch.waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open Empty Workspace Window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["rk.workspace.rail"].firstMatch.waitForExistence(timeout: 10))
        let sidebar = app.descendants(matching: .any)["rk.workspace.sidebar"].firstMatch
        let inspector = app.descendants(matching: .any)["rk.workspace.inspector"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 5) && sidebar.isHittable)
        XCTAssertFalse(inspector.exists && inspector.isHittable, "o inspetor começa fechado")
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toggle Inspector"].click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 5))
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toggle Sidebar"].click()
        let hidden = expectation(for: NSPredicate(format: "exists == false OR hittable == false"), evaluatedWith: sidebar)
        wait(for: [hidden], timeout: 5)
        app.terminate()
    }

    func testDebugCommandOpensEmptyWorkspaceWindow() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 10))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open Empty Workspace Window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["rk.workspace.split"].firstMatch.waitForExistence(timeout: 10))
        app.terminate()
    }
}
