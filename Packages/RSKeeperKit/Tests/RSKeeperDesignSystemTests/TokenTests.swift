import AppKit
import Foundation
import Testing
@testable import RSKeeperDesignSystem

/// Cor sRGB com alfa, lida do JSON de tokens.
private struct RGBA: Equatable {
    var r: Double, g: Double, b: Double, a: Double

    func composited(over background: RGBA) -> RGBA {
        RGBA(r: r * a + background.r * (1 - a), g: g * a + background.g * (1 - a), b: b * a + background.b * (1 - a), a: 1)
    }

    var luminance: Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(r) + 0.7152 * channel(g) + 0.0722 * channel(b)
    }

    static func contrast(_ a: RGBA, _ b: RGBA) -> Double {
        let (l1, l2) = (a.luminance, b.luminance)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

private struct Tokens {
    let primitives: [String: [String: String]]
    let semantic: [String: [String: String]]
    let normal: [[String: Any]]
    let highContrast: [[String: Any]]

    static func load() throws -> Tokens {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/tokens.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        return Tokens(primitives: json["primitives"] as! [String: [String: String]],
                      semantic: json["semantic"] as! [String: [String: String]],
                      normal: json["contrastRequirements"] as! [[String: Any]],
                      highContrast: json["highContrastRequirements"] as! [[String: Any]])
    }

    func resolve(_ raw: String) -> RGBA {
        var value = raw
        var alpha = 1.0
        if let at = raw.firstIndex(of: "@") { value = String(raw[..<at]); alpha = Double(raw[raw.index(after: at)...])! }
        if !value.hasPrefix("#") {
            let parts = value.split(separator: ".")
            var color = resolve(primitives[String(parts[0])]![String(parts[1])]!)
            color.a = alpha
            return color
        }
        let n = Int(value.dropFirst(), radix: 16)!
        return RGBA(r: Double((n >> 16) & 0xFF) / 255, g: Double((n >> 8) & 0xFF) / 255, b: Double(n & 0xFF) / 255, a: alpha)
    }

    func color(_ token: String, variant: String) -> RGBA {
        let variants = semantic[token]!
        let fallback = variant.hasSuffix("HC") ? String(variant.dropLast(2)) : variant
        return resolve(variants[variant] ?? variants[fallback]!)
    }
}

@Suite("Design system — tokens e temas (W0-T25, NT-A11Y-04)")
struct TokenTests {
    @Test("Todo token do JSON tem enum e colorset, e vice-versa")
    func catalogMatchesSource() throws {
        let tokens = try Tokens.load()
        #expect(Set(tokens.semantic.keys) == Set(RKColorToken.allCases.map(\.rawValue)))
        for token in RKColorToken.allCases {
            #expect(NSColor(named: token.assetName, bundle: RSKeeperDesignSystem.resourceBundle) != nil, "\(token.rawValue)")
        }
    }

    @Test("Mesma cor em AppKit e no JSON, nos modos claro e escuro")
    func appKitColorsMatchSource() throws {
        let tokens = try Tokens.load()
        for (appearanceName, variant) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            for token in RKColorToken.allCases {
                let expected = tokens.color(token.rawValue, variant: variant)
                var actual = RGBA(r: 0, g: 0, b: 0, a: 0)
                appearance.performAsCurrentDrawingAppearance {
                    let c = RKColor.nsColor(token).usingColorSpace(.sRGB)!
                    actual = RGBA(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
                }
                let close = abs(actual.r - expected.r) < 0.003 && abs(actual.g - expected.g) < 0.003
                    && abs(actual.b - expected.b) < 0.003 && abs(actual.a - expected.a) < 0.003
                #expect(close, "\(token.rawValue) [\(variant)]: catálogo \(actual) ≠ JSON \(expected)")
            }
        }
    }

    /// Alto contraste depende do ajuste "Aumentar contraste" do sistema e não é simulável por
    /// `NSAppearance` em teste (verificado: nem as cores do sistema mudam). Aqui se confere que o
    /// catálogo gerado contém as variantes de alto contraste com os valores da fonte.
    @Test("Variantes de alto contraste presentes no catálogo gerado, com os valores da fonte")
    func highContrastVariantsInCatalog() throws {
        let tokens = try Tokens.load()
        let catalog = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/RSKeeperDesignSystem/Resources/Colors.xcassets")
        for token in RKColorToken.allCases {
            let url = catalog.appendingPathComponent("\(token.assetName).colorset/Contents.json")
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let colors = json["colors"] as! [[String: Any]]
            #expect(colors.count == 4, "\(token.rawValue): esperado any/dark/hc/dark-hc")
            for (entry, variant) in zip(colors, ["light", "dark", "lightHC", "darkHC"]) {
                let components = (entry["color"] as! [String: Any])["components"] as! [String: String]
                let expected = tokens.color(token.rawValue, variant: variant)
                let red = Double(Int(components["red"]!.dropFirst(2), radix: 16)!) / 255
                let alpha = Double(components["alpha"]!)!
                #expect(abs(red - expected.r) < 0.003 && abs(alpha - expected.a) < 0.003, "\(token.rawValue) [\(variant)]")
            }
        }
    }

    @Test("NT-A11Y-04: contrastes mínimos nos modos claro e escuro")
    func contrastNormal() throws {
        let tokens = try Tokens.load()
        for variant in ["light", "dark"] { try checkContrast(tokens, tokens.normal, variant) }
    }

    @Test("NT-A11Y-04: contrastes mínimos em alto contraste")
    func contrastHigh() throws {
        let tokens = try Tokens.load()
        for variant in ["lightHC", "darkHC"] { try checkContrast(tokens, tokens.highContrast, variant) }
    }

    private func checkContrast(_ tokens: Tokens, _ rules: [[String: Any]], _ variant: String) throws {
        for rule in rules {
            let foregroundName = rule["foreground"] as! String
            let minimum = rule["min"] as! Double
            for backgroundName in rule["backgrounds"] as! [String] {
                let background = tokens.color(backgroundName, variant: variant)
                let foreground = tokens.color(foregroundName, variant: variant).composited(over: background)
                let ratio = RGBA.contrast(foreground, background)
                #expect(ratio >= minimum, "\(foregroundName) sobre \(backgroundName) [\(variant)]: \(String(format: "%.2f", ratio)) < \(minimum)")
            }
        }
    }

    @Test("Nenhuma cor de marca do Beekeeper nos tokens (docs/native/07 §13)")
    func noBeekeeperColors() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("design/tokens.json")
        let text = try String(contentsOf: url, encoding: .utf8).uppercased()
        for forbidden in ["#FAD83B", "#F9CE09", "#4AD0FF", "#0099FF"] {
            #expect(!text.contains(forbidden), "\(forbidden) presente")
        }
    }

    @Test("Tipografia: SF Mono só em código e dados; escala crescente")
    func typography() {
        #expect(RKTypography.code.isMonospaced && RKTypography.data.isMonospaced)
        #expect(!RKTypography.body.isMonospaced)
        #expect(RKTypography.code.nsFont.isFixedPitch)
        #expect(RKTypography.caption.size < RKTypography.body.size && RKTypography.body.size < RKTypography.title1.size)
        #expect(RKDensity.compact.gridRowHeight == 22 && RKDensity.comfortable.gridRowHeight == 28)
    }
}
