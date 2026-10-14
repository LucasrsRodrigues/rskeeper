#if RSK_DEV_BUILD || RSK_TEST_BUILD
import Foundation
import RSKeeperDomain
import RSKeeperDriversCore
import RSKeeperDriverSQLite

/// Banco SQLite de amostra para depuração e XCUITest (só Dev/Test): o painel de arquivos do sistema não é
/// automatizável. O arquivo fica no temporário do próprio app (fora da raiz de dados) e entra no
/// formulário pela mesma concessão por bookmark que um arquivo escolhido no painel.
enum SampleDatabase {
    static let notification = Notification.Name("rsk.debug.useSampleDatabase")

    static func create() async throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("amostra-\(UUID().uuidString.prefix(8)).db")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let connection = try await SQLiteDriver().open(.file(path: url.path, readOnly: false), options: OpenOptions())
        for sql in [
            "CREATE TABLE pedidos (id INTEGER PRIMARY KEY, cliente TEXT NOT NULL, total NUMERIC, criado_em DATETIME)",
            "WITH RECURSIVE g(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM g WHERE x < 500) INSERT INTO pedidos (cliente, total, criado_em) SELECT 'cliente ' || x, x * 10.5, datetime('2026-01-01', '+' || x || ' hours') FROM g",
        ] {
            _ = try await connection.execute(BoundStatement(sql: sql), limits: .default)
        }
        await connection.close()
        return url
    }
}
#endif
