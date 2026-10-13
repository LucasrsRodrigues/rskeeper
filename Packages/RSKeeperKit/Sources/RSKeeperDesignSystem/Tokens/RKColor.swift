import AppKit
import SwiftUI

/// Acesso às cores dos tokens, **as mesmas** em SwiftUI e AppKit (W0-T25, aceite 2; docs/native/07 §12).
/// A fonte é o asset catalog do módulo, gerado de `design/tokens.json`.
public enum RKColor {
    /// Cor SwiftUI do token.
    public static func color(_ token: RKColorToken) -> Color {
        Color(token.assetName, bundle: .module)
    }

    /// Cor AppKit do token (para `NSTableView`, `NSTextView`, `NSOutlineView`).
    public static func nsColor(_ token: RKColorToken) -> NSColor {
        guard let color = NSColor(named: token.assetName, bundle: .module) else {
            assertionFailure("token sem cor no catálogo: \(token.rawValue)")
            return .magenta
        }
        return color
    }
}

extension Color {
    /// `Color.rk(.accent)`
    public static func rk(_ token: RKColorToken) -> Color { RKColor.color(token) }
}

extension ShapeStyle where Self == Color {
    /// `.foregroundStyle(.rk(.textSecondary))`
    public static func rk(_ token: RKColorToken) -> Color { RKColor.color(token) }
}
