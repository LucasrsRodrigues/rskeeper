import AppKit
import SwiftUI

/// Tokens de tipografia (docs/native/07 §4). SF Pro na interface e SF Mono em código e dados,
/// via fontes do sistema (nenhuma fonte empacotada).
public enum RKTypography: String, CaseIterable, Sendable {
    case caption2, caption, bodyCompact, body, bodyEmphasis, title3, title2, title1, code, data, section

    public var size: CGFloat {
        switch self {
        case .caption2: 10
        case .caption, .section: 11
        case .bodyCompact, .data: 12
        case .body, .bodyEmphasis, .code: 13
        case .title3: 15
        case .title2: 17
        case .title1: 22
        }
    }

    public var lineHeight: CGFloat {
        switch self {
        case .caption2: 13
        case .caption, .section: 14
        case .bodyCompact, .data: 16
        case .body, .bodyEmphasis: 17
        case .code: 19
        case .title3: 20
        case .title2: 22
        case .title1: 28
        }
    }

    public var weight: Font.Weight {
        switch self {
        case .bodyEmphasis, .title3, .title2, .section: .semibold
        case .title1: .bold
        default: .regular
        }
    }

    public var isMonospaced: Bool { self == .code || self == .data }

    /// Fonte SwiftUI do token. Dígitos tabulares em dados e código.
    public var font: Font {
        let base = Font.system(size: size, weight: weight, design: isMonospaced ? .monospaced : .default)
        return isMonospaced ? base.monospacedDigit() : base
    }

    /// Fonte AppKit equivalente.
    public var nsFont: NSFont {
        let nsWeight: NSFont.Weight = switch weight {
        case .semibold: .semibold
        case .bold: .bold
        default: .regular
        }
        return isMonospaced ? .monospacedSystemFont(ofSize: size, weight: nsWeight) : .systemFont(ofSize: size, weight: nsWeight)
    }

    /// Espaçamento extra de letras (cabeçalhos de seção em caixa alta).
    public var tracking: CGFloat { self == .section ? 0.6 : 0 }
}

extension View {
    /// Aplica o token tipográfico (fonte e tracking).
    public func rkTypography(_ token: RKTypography) -> some View {
        font(token.font).tracking(token.tracking)
    }
}
