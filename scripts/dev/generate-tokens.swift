// Gera o asset catalog de cores e o enum de tokens a partir de design/tokens.json (W0-T25).
// Uso (na raiz do repositório): swift scripts/dev/generate-tokens.swift
// Saídas (sobrescritas; não editar à mão):
//   Packages/RSKeeperKit/Sources/RSKeeperDesignSystem/Resources/Colors.xcassets/<token>.colorset
//   Packages/RSKeeperKit/Sources/RSKeeperDesignSystem/Tokens/RKColorToken.generated.swift
import Foundation

struct RGBA { var r: Int; var g: Int; var b: Int; var a: Double }

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let tokensURL = root.appendingPathComponent("design/tokens.json")
let catalog = root.appendingPathComponent("Packages/RSKeeperKit/Sources/RSKeeperDesignSystem/Resources/Colors.xcassets")
let swiftOut = root.appendingPathComponent("Packages/RSKeeperKit/Sources/RSKeeperDesignSystem/Tokens/RKColorToken.generated.swift")

let json = try JSONSerialization.jsonObject(with: Data(contentsOf: tokensURL)) as! [String: Any]
let primitives = json["primitives"] as! [String: [String: String]]
let semantic = json["semantic"] as! [String: [String: String]]

func resolve(_ raw: String) -> RGBA {
    var value = raw
    var alpha = 1.0
    if let at = raw.firstIndex(of: "@") {
        value = String(raw[..<at])
        alpha = Double(raw[raw.index(after: at)...])!
    }
    if !value.hasPrefix("#") {
        let parts = value.split(separator: ".")
        guard parts.count == 2, let hex = primitives[String(parts[0])]?[String(parts[1])] else {
            fatalError("primitiva desconhecida: \(raw)")
        }
        var resolved = resolve(hex)
        resolved.a = alpha
        return resolved
    }
    let hex = value.dropFirst()
    precondition(hex.count == 6, "hex inválido: \(raw)")
    let number = Int(hex, radix: 16)!
    return RGBA(r: (number >> 16) & 0xFF, g: (number >> 8) & 0xFF, b: number & 0xFF, a: alpha)
}

func colorEntry(_ c: RGBA, appearances: [[String: String]]) -> [String: Any] {
    var entry: [String: Any] = [
        "idiom": "universal",
        "color": [
            "color-space": "srgb",
            "components": [
                "red": String(format: "0x%02X", c.r), "green": String(format: "0x%02X", c.g),
                "blue": String(format: "0x%02X", c.b), "alpha": String(format: "%.3f", c.a),
            ],
        ],
    ]
    if !appearances.isEmpty { entry["appearances"] = appearances }
    return entry
}

func assetName(_ token: String) -> String { token.replacingOccurrences(of: ".", with: "-") }

func caseName(_ token: String) -> String {
    let parts = token.split(separator: ".").map(String.init)
    return parts.enumerated().map { index, part in
        index == 0 ? part : part.prefix(1).uppercased() + part.dropFirst()
    }.joined()
}

let fileManager = FileManager.default
// Remove colorsets gerados anteriormente (mantém o Contents.json do catálogo).
if let items = try? fileManager.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil) {
    for item in items where item.pathExtension == "colorset" { try fileManager.removeItem(at: item) }
}
try fileManager.createDirectory(at: catalog, withIntermediateDirectories: true)
try Data("{\n  \"info\" : {\n    \"author\" : \"xcode\",\n    \"version\" : 1\n  }\n}\n".utf8)
    .write(to: catalog.appendingPathComponent("Contents.json"))

let dark = [["appearance": "luminosity", "value": "dark"]]
let highContrast = [["appearance": "contrast", "value": "high"]]
let darkHighContrast = dark + highContrast

for (token, variants) in semantic.sorted(by: { $0.key < $1.key }) {
    let light = resolve(variants["light"]!)
    let darkColor = resolve(variants["dark"]!)
    let lightHC = resolve(variants["lightHC"] ?? variants["light"]!)
    let darkHC = resolve(variants["darkHC"] ?? variants["dark"]!)
    let contents: [String: Any] = [
        "colors": [
            colorEntry(light, appearances: []),
            colorEntry(darkColor, appearances: dark),
            colorEntry(lightHC, appearances: highContrast),
            colorEntry(darkHC, appearances: darkHighContrast),
        ],
        "info": ["author": "xcode", "version": 1],
    ]
    let folder = catalog.appendingPathComponent("\(assetName(token)).colorset")
    try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
    let data = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: folder.appendingPathComponent("Contents.json"))
}

var swift = """
// GERADO por scripts/dev/generate-tokens.swift a partir de design/tokens.json — não editar.

/// Tokens semânticos de cor do RSKeeper (docs/native/07 §2). Componentes usam só estes tokens.
public enum RKColorToken: String, CaseIterable, Sendable {

"""
for token in semantic.keys.sorted() {
    swift += "    case \(caseName(token)) = \"\(token)\"\n"
}
swift += """

    /// Nome do colorset no asset catalog.
    public var assetName: String { rawValue.replacingOccurrences(of: ".", with: "-") }
}

"""
try fileManager.createDirectory(at: swiftOut.deletingLastPathComponent(), withIntermediateDirectories: true)
try Data(swift.utf8).write(to: swiftOut)
print("ok: \(semantic.count) tokens")
