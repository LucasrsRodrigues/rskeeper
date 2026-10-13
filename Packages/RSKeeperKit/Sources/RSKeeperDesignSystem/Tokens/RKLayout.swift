import CoreGraphics

/// Espaçamento em grade de 4 pt (docs/native/07 §5.1).
public enum RKSpacing {
    public static let s0: CGFloat = 0
    public static let half: CGFloat = 2
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 20
    public static let s6: CGFloat = 24
    public static let s8: CGFloat = 32
    public static let s10: CGFloat = 40
}

/// Raios (docs/native/07 §5.2). A janela usa o raio do sistema.
public enum RKRadius {
    public static let small: CGFloat = 4
    public static let control: CGFloat = 6
    public static let card: CGFloat = 10
    public static let panel: CGFloat = 12
}

/// Densidade (docs/native/07 §5.4). Compacto é o padrão.
public enum RKDensity: String, CaseIterable, Sendable {
    case compact, comfortable

    public var gridRowHeight: CGFloat { self == .compact ? 22 : 28 }
    public var listRowHeight: CGFloat { self == .compact ? 22 : 26 }
    public var tabHeight: CGFloat { self == .compact ? 30 : 34 }
    public var controlHeight: CGFloat { self == .compact ? 22 : 28 }
    public var statusBarHeight: CGFloat { self == .compact ? 24 : 26 }
}

/// Movimento (docs/native/07 §7): durações curtas; com "Reduzir movimento", sem animação.
public enum RKMotion {
    public static let fast: Double = 0.12
    public static let standard: Double = 0.2
    public static let slow: Double = 0.3
}
