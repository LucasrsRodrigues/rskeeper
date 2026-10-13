// Gera o ícone PROVISÓRIO e PRÓPRIO do RSKeeper (W0-T08).
// Desenho original: quadrado arredondado com gradiente teal (tokens rk.prim.teal) e
// as letras "RK". Não usa nenhum ativo de terceiros.
// Uso: swift scripts/dev/make-placeholder-icon.swift <diretório .appiconset>
import AppKit

let outDir = URL(fileURLWithPath: CommandLine.arguments[1])
let sizes: [(points: Int, scale: Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(pixels)
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    let gradient = NSGradient(starting: NSColor(srgbRed: 0x3F/255, green: 0xBF/255, blue: 0xC4/255, alpha: 1),
                              ending: NSColor(srgbRed: 0x12/255, green: 0x6A/255, blue: 0x6F/255, alpha: 1))!
    gradient.draw(in: path, angle: -90)
    let text = "RK" as NSString
    let font = NSFont.systemFont(ofSize: rect.width * 0.42, weight: .bold)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let size = text.size(withAttributes: attrs)
    text.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (pt, scale) in sizes {
    let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
    try! render(pixels: pt * scale).write(to: outDir.appendingPathComponent(name))
    images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(pt)x\(pt)"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
let json = try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
try! json.write(to: outDir.appendingPathComponent("Contents.json"))
print("ok: \(images.count) imagens")
