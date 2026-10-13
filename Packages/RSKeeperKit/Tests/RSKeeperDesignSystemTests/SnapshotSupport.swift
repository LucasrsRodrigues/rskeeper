import AppKit
import SwiftUI
import Testing

/// Infraestrutura de snapshot própria (W0-T30; decisão E-6: sem dependência externa).
///
/// - Renderiza a view offscreen num `NSHostingView` com aparência e tamanho fixos (escala 2x).
/// - Compara com a referência PNG em `__Snapshots__/`. Tolerância: canal com diferença > 8/255
///   conta como pixel diferente; falha acima de 0,5% dos pixels (antisserrilhado de texto).
/// - Referência ausente ou `RSK_RECORD_SNAPSHOTS=1`: grava e registra falha (rodar de novo para validar).
/// - Determinismo: mesma máquina de referência (Xcode 27.0, macOS 26.x) e fontes do sistema.
@MainActor
enum Snapshot {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("__Snapshots__")

    static func render<V: View>(_ view: V, size: CGSize, appearance: NSAppearance.Name) -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: appearance)
        host.layoutSubtreeIfNeeded()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }

    static func assert<V: View>(_ view: V, named name: String, size: CGSize, appearance: NSAppearance.Name,
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let rep = render(view, size: size, appearance: appearance)
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let reference = directory.appendingPathComponent("\(name).png")
        let record = ProcessInfo.processInfo.environment["RSK_RECORD_SNAPSHOTS"] == "1"
        if record || !FileManager.default.fileExists(atPath: reference.path) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try png.write(to: reference)
            Issue.record("referência gravada: \(name).png — rode de novo para validar", sourceLocation: sourceLocation)
            return
        }
        let expected = try #require(NSBitmapImageRep(data: Data(contentsOf: reference)))
        // Os dois lados passam pelo mesmo caminho (PNG codificado → decodificado) antes de comparar.
        let current = try #require(NSBitmapImageRep(data: png))
        let ratio = difference(current, expected)
        #expect(ratio <= 0.005, "\(name): \(String(format: "%.3f%%", ratio * 100)) dos pixels diferem", sourceLocation: sourceLocation)
    }

    /// Fração de pixels com algum canal diferindo mais que 8/255.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Double {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var different = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let ca = a.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      let cb = b.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { different += 1; continue }
                let delta = max(abs(ca.redComponent - cb.redComponent), abs(ca.greenComponent - cb.greenComponent),
                                abs(ca.blueComponent - cb.blueComponent), abs(ca.alphaComponent - cb.alphaComponent))
                if delta > 8.0 / 255.0 { different += 1 }
            }
        }
        return Double(different) / Double(a.pixelsWide * a.pixelsHigh)
    }
}
