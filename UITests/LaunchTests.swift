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
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Welcome to RSKeeper"].waitForExistence(timeout: 15))
        app.terminate()
    }

    func testConnectionsWindowAppearsInPortuguese() {
        let app = launch(language: "pt-BR")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Bem-vindo ao RSKeeper"].waitForExistence(timeout: 15))
        app.terminate()
    }

    /// NST-13-01, crit. 1: sem conexão, comandos de conexão e de consulta ficam desabilitados.
    func testConnectionCommandsDisabledWithoutConnection() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 20))
        app.menuBars.menuBarItems["Query"].click()
        XCTAssertTrue(app.menuItems["Run All"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.menuItems["Run All"].isEnabled)
        XCTAssertFalse(app.menuItems["Cancel Execution"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.menuBars.menuBarItems["File"].click()
        XCTAssertFalse(app.menuItems["Disconnect"].isEnabled)
        XCTAssertTrue(app.menuItems["New Connection…"].isEnabled)
        app.typeKey(.escape, modifierFlags: [])
        app.terminate()
    }

    /// Cria e conecta a conexão de amostra (SQLite) e devolve a janela de workspace.
    @discardableResult
    private func connectSample(_ app: XCUIApplication, name: String) -> XCUIElement {
        XCTAssertTrue(app.buttons["rk.connections.new"].waitForExistence(timeout: 20))
        app.buttons["rk.connections.new"].click()
        let sqlite = app.descendants(matching: .any)["rk.driverPicker.item.sqlite"].firstMatch
        XCTAssertTrue(sqlite.waitForExistence(timeout: 15))
        sqlite.click()
        app.buttons["rk.driverPicker.next"].click()
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Use Sample Database File"].click()
        let field = app.textFields["rk.connections.form.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(name)
        app.buttons["rk.connections.form.connect"].click()
        let window = app.windows[name]
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        return window
    }

    /// NST-05-02: explorador com a tabela de amostra; filtro; colunas ao expandir.
    func testExplorerShowsSampleTable() {
        let app = launch(language: "en")
        let window = connectSample(app, name: "Explorer UI")
        let tree = window.outlines.firstMatch
        let entity = tree.cells["pedidos"].firstMatch
        XCTAssertTrue(entity.waitForExistence(timeout: 20))
        let filter = window.textFields.matching(NSPredicate(format: "placeholderValue == 'Filter entities'")).firstMatch
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        filter.click()
        filter.typeText("zzz")
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: entity)
        wait(for: [gone], timeout: 15)
        filter.typeKey("a", modifierFlags: .command)
        filter.typeText("ped")
        XCTAssertTrue(entity.waitForExistence(timeout: 15))
        // Teclado (crit. 5): foco na árvore, type-select seleciona a tabela, → expande e mostra as colunas.
        tree.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.02)).click()
        window.typeText("pedidos")
        window.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertTrue(tree.cells.matching(NSPredicate(format: "label BEGINSWITH 'cliente'")).firstMatch.waitForExistence(timeout: 15))
        app.terminate()
    }

    /// NST-05-03: barra de status com conexão, driver e ambiente em texto; menu Desconectar.
    func testStatusBarShowsConnectionAndDisconnects() {
        let app = launch(language: "en")
        let window = connectSample(app, name: "Status UI")
        let connection = window.descendants(matching: .any)["rk.status.connection"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 15))
        // O botão de menu expõe nome e driver no próprio rótulo.
        XCTAssertTrue(connection.label.contains("Status UI") && connection.label.contains("SQLite"), connection.label)
        XCTAssertTrue(window.staticTexts["LOCAL"].firstMatch.exists, "o ambiente aparece em texto")
        connection.click()
        let disconnect = app.menuItems["rk.status.disconnect"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 15))
        disconnect.click()
        XCTAssertTrue(window.descendants(matching: .any)["rk.status.disconnected"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()
    }

    /// NST-03-01…05: nova conexão → seletor de driver → formulário SQLite → testar → conectar → workspace
    /// com o título da conexão; a conexão aparece em "Recentes".
    func testCreateTestAndConnectSQLite() {
        let app = launch(language: "en")
        XCTAssertTrue(app.buttons["rk.connections.new"].waitForExistence(timeout: 20))
        app.buttons["rk.connections.new"].click()
        let sqlite = app.descendants(matching: .any)["rk.driverPicker.item.sqlite"].firstMatch
        XCTAssertTrue(sqlite.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["rk.driverPicker.next"].isEnabled, "Avançar só com seleção (CAP-03)")
        sqlite.click()
        app.buttons["rk.driverPicker.next"].click()
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Use Sample Database File"].click()
        let name = app.textFields["rk.connections.form.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 20))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Amostra UI")
        app.buttons["rk.connections.form.test"].click()
        let result = app.descendants(matching: .any)["rk.connections.form.result"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'SQLite'")).firstMatch.exists
                      || result.label.contains("SQLite"))
        app.buttons["rk.connections.form.connect"].click()
        XCTAssertTrue(app.windows["Amostra UI"].waitForExistence(timeout: 20), "o título da janela identifica a conexão")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.row.Amostra UI"].firstMatch.waitForExistence(timeout: 15))
        app.terminate()
    }

    /// NST-05-01: shell de quatro regiões; o menu Visualizar mostra/oculta sidebar e inspetor.
    func testWorkspaceShellTogglesRegions() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].firstMatch.waitForExistence(timeout: 20))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open Empty Workspace Window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["rk.workspace.rail"].firstMatch.waitForExistence(timeout: 20))
        let sidebar = app.descendants(matching: .any)["rk.workspace.sidebar"].firstMatch
        let inspector = app.descendants(matching: .any)["rk.workspace.inspector"].firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 15) && sidebar.isHittable)
        XCTAssertFalse(inspector.exists && inspector.isHittable, "o inspetor começa fechado")
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toggle Inspector"].click()
        XCTAssertTrue(inspector.waitForExistence(timeout: 15))
        app.menuBars.menuBarItems["View"].click()
        app.menuItems["Toggle Sidebar"].click()
        let hidden = expectation(for: NSPredicate(format: "exists == false OR hittable == false"), evaluatedWith: sidebar)
        wait(for: [hidden], timeout: 15)
        app.terminate()
    }

    func testDebugCommandOpensEmptyWorkspaceWindow() {
        let app = launch(language: "en")
        XCTAssertTrue(app.descendants(matching: .any)["rk.connections.emptyState"].waitForExistence(timeout: 20))
        app.menuBars.menuBarItems["Debug"].click()
        app.menuItems["Open Empty Workspace Window"].click()
        XCTAssertTrue(app.descendants(matching: .any)["rk.workspace.split"].firstMatch.waitForExistence(timeout: 20))
        app.terminate()
    }
}
