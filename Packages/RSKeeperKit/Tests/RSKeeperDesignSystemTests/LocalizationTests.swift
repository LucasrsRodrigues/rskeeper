import Foundation
import Testing
@testable import RSKeeperDesignSystem

/// W0-T28 — String Catalog pt-BR e en: toda chave usada no código existe e está traduzida.
@Suite("Localização do Design System (W0-T28)")
struct LocalizationTests {
    private static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/RSKeeperDesignSystem")

    private static func catalog() throws -> [String: Any] {
        let url = sources.appendingPathComponent("Resources/Localizable.xcstrings")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return json["strings"] as! [String: Any]
    }

    /// Chaves usadas em `String(localized: "…", bundle: .module)` e `labelKey`.
    private static func usedKeys() throws -> Set<String> {
        var keys: Set<String> = []
        let regex = try NSRegularExpression(pattern: #"String\(localized:\s*"((?:[^"\\]|\\.)*)""#)
        let caseRegex = try NSRegularExpression(pattern: #"case \.\w+: "([^"]+)""#)
        let enumerator = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift", !url.lastPathComponent.contains("Gallery") else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: range) {
                var key = String(text[Range(match.range(at: 1), in: text)!])
                key = key.replacingOccurrences(of: #"\(count)"#, with: "%lld")
                keys.insert(key)
            }
            if url.lastPathComponent == "Buttons.swift" {
                for match in caseRegex.matches(in: text, range: range) { keys.insert(String(text[Range(match.range(at: 1), in: text)!])) }
            }
        }
        return keys
    }

    @Test("Nenhuma chave usada está ausente do catálogo ou sem tradução pt-BR")
    func noMissingKeys() throws {
        let catalog = try Self.catalog()
        let used = try Self.usedKeys()
        #expect(used.count >= 15)
        for key in used {
            let entry = catalog[key] as? [String: Any]
            #expect(entry != nil, "chave ausente no catálogo: \(key)")
            let localizations = entry?["localizations"] as? [String: Any]
            #expect(localizations?["pt-BR"] != nil, "sem pt-BR: \(key)")
        }
    }

    @Test("O bundle compilado traduz para pt-BR e mantém inglês")
    func compiledBundleTranslates() throws {
        let bundle = RSKeeperDesignSystem.resourceBundle
        let resources = try #require(bundle.resourceURL)
        let pt = try #require(Bundle(url: resources.appendingPathComponent("pt-BR.lproj")))
        let en = try #require(Bundle(url: resources.appendingPathComponent("en.lproj")))
        #expect(pt.localizedString(forKey: "Run All", value: nil, table: nil) == "Executar tudo")
        #expect(en.localizedString(forKey: "Run All", value: nil, table: nil) == "Run All")
        #expect(pt.localizedString(forKey: "Run Selection", value: nil, table: nil) == "Executar seleção")
    }
}
