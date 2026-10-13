import SwiftUI

/// Variantes de botão (docs/native/07 §8.1).
public enum RKButtonVariant: Sendable, CaseIterable {
    case primary, secondary, ghost, destructive
}

/// Estilo de botão do RSKeeper: estados padrão, hover, pressionado, foco (anel), desabilitado e carregando.
public struct RKButtonStyle: ButtonStyle {
    public let variant: RKButtonVariant
    public let isLoading: Bool
    public let density: RKDensity

    public init(_ variant: RKButtonVariant = .secondary, isLoading: Bool = false, density: RKDensity = .compact) {
        self.variant = variant
        self.isLoading = isLoading
        self.density = density
    }

    public func makeBody(configuration: Configuration) -> some View {
        RKButtonBody(configuration: configuration, variant: variant, isLoading: isLoading, density: density)
    }
}

private struct RKButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let variant: RKButtonVariant
    let isLoading: Bool
    let density: RKDensity

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var isHovered = false

    var body: some View {
        ZStack {
            configuration.label
                .opacity(isLoading ? 0 : 1)                          // mantém a largura ao carregar
            if isLoading { ProgressView().controlSize(.small).tint(foreground) }
        }
        .rkTypography(variant == .primary ? .bodyEmphasis : .body)
        .foregroundStyle(foreground)
        .padding(.horizontal, density == .compact ? RKSpacing.s2 + RKSpacing.half : RKSpacing.s3)
        .frame(minHeight: density.controlHeight)
        .background(background, in: RoundedRectangle(cornerRadius: RKRadius.control))
        .overlay {
            RoundedRectangle(cornerRadius: RKRadius.control)
                .strokeBorder(variant == .secondary ? Color.rk(.separatorStrong) : .clear, lineWidth: 1)
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: RKRadius.control + 2)
                    .stroke(Color.rk(.focusRing), lineWidth: 2)
                    .padding(-2)
            }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(RoundedRectangle(cornerRadius: RKRadius.control))
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isLoading ? .updatesFrequently : [])
    }

    private var foreground: Color {
        switch variant {
        case .primary: .rk(.textOnAccent)
        case .destructive: .white
        case .secondary, .ghost: .rk(.textPrimary)
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch variant {
        case .primary: return .rk(isHovered && !pressed ? .accentFillHover : .accentFill)
        case .destructive: return .rk(.dangerFill).opacity(pressed ? 0.85 : 1)
        case .secondary: return .rk(pressed ? .hover : .surfaceRaised)
        case .ghost: return isHovered || pressed ? .rk(.hover) : .clear
        }
    }
}

extension ButtonStyle where Self == RKButtonStyle {
    public static func rk(_ variant: RKButtonVariant = .secondary, isLoading: Bool = false) -> RKButtonStyle {
        RKButtonStyle(variant, isLoading: isLoading)
    }
}

/// Modo do botão de execução (docs/native/07 §8.1; [CONFIRMADO CAP-04/08] rótulo dinâmico).
public enum RunMode: String, Sendable, CaseIterable {
    case all, current, selection

    /// Chave de localização do rótulo.
    public var labelKey: String.LocalizationValue {
        switch self {
        case .all: "Run All"
        case .current: "Run Current"
        case .selection: "Run Selection"
        }
    }

    public var label: String { String(localized: labelKey, bundle: .module) }

    /// Modo efetivo: com seleção não vazia, executa a seleção; senão, o modo preferido.
    public static func effective(hasSelection: Bool, preferred: RunMode) -> RunMode {
        hasSelection ? .selection : (preferred == .selection ? .all : preferred)
    }
}

/// Botão dividido de execução: ação principal com rótulo dinâmico + seta com alternativas.
public struct RKSplitButton<MenuContent: View>: View {
    private let title: String
    private let systemImage: String
    private let isLoading: Bool
    private let action: () -> Void
    private let menu: () -> MenuContent

    public init(_ title: String, systemImage: String = "play.fill", isLoading: Bool = false,
                action: @escaping () -> Void, @ViewBuilder menu: @escaping () -> MenuContent) {
        self.title = title
        self.systemImage = systemImage
        self.isLoading = isLoading
        self.action = action
        self.menu = menu
    }

    public var body: some View {
        HStack(spacing: 0) {
            Button(action: action) {
                Label(title, systemImage: systemImage).labelStyle(.titleAndIcon)
            }
            .buttonStyle(RKButtonStyle(.primary, isLoading: isLoading))
            .accessibilityLabel(Text(title))
            Menu {
                menu()
            } label: {
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(RKButtonStyle(.primary))
            .fixedSize()
            .accessibilityLabel(Text(String(localized: "More run options", bundle: .module)))
        }
    }
}
