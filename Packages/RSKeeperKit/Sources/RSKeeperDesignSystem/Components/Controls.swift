import SwiftUI

/// Campo de texto do RSKeeper: fundo `surface.inset`, borda `separator.strong`, anel de foco,
/// estado de erro com mensagem e ícone (docs/native/07 §8.4).
public struct RKTextField: View {
    private let title: String
    @Binding private var text: String
    private let isMonospaced: Bool
    private let errorMessage: String?
    @FocusState private var focused: Bool

    public init(_ title: String, text: Binding<String>, monospaced: Bool = false, error: String? = nil) {
        self.title = title
        self._text = text
        self.isMonospaced = monospaced
        self.errorMessage = error
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: RKSpacing.s1) {
            TextField(title, text: $text)
                .textFieldStyle(.plain)
                .font(isMonospaced ? RKTypography.code.font : RKTypography.body.font)
                .focused($focused)
                .padding(.horizontal, RKSpacing.s2)
                .frame(minHeight: RKDensity.compact.controlHeight + 2)
                .background(Color.rk(.surfaceInset), in: RoundedRectangle(cornerRadius: RKRadius.control))
                .overlay {
                    RoundedRectangle(cornerRadius: RKRadius.control)
                        .strokeBorder(borderColor, lineWidth: focused ? 2 : 1)
                }
                .accessibilityLabel(Text(title))
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .rkTypography(.caption)
                    .foregroundStyle(.rk(.danger))
                    .accessibilityLabel(Text(errorMessage))
            }
        }
    }

    private var borderColor: Color {
        if errorMessage != nil { return .rk(.danger) }
        return focused ? .rk(.focusRing) : .rk(.separatorStrong)
    }
}

/// Campo de busca: lupa, limpar com Esc ou botão; busca local, sem rede (07 §8.5).
public struct RKSearchField: View {
    private let prompt: String
    @Binding private var text: String

    public init(_ prompt: String, text: Binding<String>) {
        self.prompt = prompt
        self._text = text
    }

    public var body: some View {
        HStack(spacing: RKSpacing.s1) {
            Image(systemName: "magnifyingglass").foregroundStyle(.rk(.textTertiary)).accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .rkTypography(.body)
                .onKeyPress(.escape) {
                    guard !text.isEmpty else { return .ignored }
                    text = ""
                    return .handled
                }
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.rk(.textTertiary))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(String(localized: "Clear search", bundle: .module)))
            }
        }
        .padding(.horizontal, RKSpacing.s2)
        .frame(minHeight: RKDensity.compact.controlHeight + 2)
        .background(Color.rk(.surfaceInset), in: RoundedRectangle(cornerRadius: RKRadius.control))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(prompt))
    }
}

/// Badge / pílula (07 §8.10). O tom de ambiente sempre leva texto, nunca só cor.
public struct RKBadge: View {
    public enum Tone: Sendable, CaseIterable { case neutral, accent, success, warning, danger, info }

    private let text: String
    private let tone: Tone
    private let outlined: Bool

    public init(_ text: String, tone: Tone = .neutral, outlined: Bool = false) {
        self.text = text
        self.tone = tone
        self.outlined = outlined
    }

    public var body: some View {
        Text(text)
            .rkTypography(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(outlined ? color : .rk(.textPrimary))
            .padding(.horizontal, RKSpacing.s1 + RKSpacing.half)
            .padding(.vertical, 1)
            .background(outlined ? .clear : color.opacity(0.22), in: RoundedRectangle(cornerRadius: RKRadius.small))
            .overlay { RoundedRectangle(cornerRadius: RKRadius.small).strokeBorder(outlined ? color : .clear, lineWidth: 1) }
            .accessibilityLabel(Text(text))
    }

    private var color: Color {
        switch tone {
        case .neutral: .rk(.textSecondary)
        case .accent: .rk(.accent)
        case .success: .rk(.success)
        case .warning: .rk(.warning)
        case .danger: .rk(.danger)
        case .info: .rk(.info)
        }
    }
}

/// Contador ao lado de títulos de seção (07 §8; [CONFIRMADO CAP-04B] "ENTITIES" com contador).
public struct RKCounterBadge: View {
    private let count: Int
    public init(_ count: Int) { self.count = count }
    public var body: some View {
        Text(count, format: .number)
            .font(RKTypography.caption2.font.monospacedDigit())
            .foregroundStyle(.rk(.textSecondary))
            .padding(.horizontal, RKSpacing.s1)
            .background(Color.rk(.hover), in: Capsule())
            .accessibilityLabel(Text(String(localized: "\(count) items", bundle: .module)))
    }
}

/// Indicador de progresso: indeterminado (spinner) ou determinado (barra fina de 2 pt) — 07 §8.14.
public struct RKProgress: View {
    private let fraction: Double?
    public init(fraction: Double? = nil) { self.fraction = fraction }
    public var body: some View {
        if let fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.rk(.separator))
                    Rectangle().fill(Color.rk(.accent)).frame(width: geometry.size.width * min(max(fraction, 0), 1))
                }
            }
            .frame(height: 2)
            .accessibilityElement()
            .accessibilityValue(Text(fraction, format: .percent.precision(.fractionLength(0))))
            .accessibilityLabel(Text(String(localized: "Progress", bundle: .module)))
        } else {
            ProgressView().controlSize(.small)
                .accessibilityLabel(Text(String(localized: "Loading", bundle: .module)))
        }
    }
}

/// Estado vazio: título, texto secundário, até 2 ações e dicas de atalho (07 §8.13; [CONFIRMADO CAP-04]).
public struct RKEmptyState<Actions: View>: View {
    private let title: String
    private let message: String?
    private let systemImage: String
    private let hints: [(label: String, keys: [String])]
    private let actions: Actions

    public init(_ title: String, message: String? = nil, systemImage: String = "tray",
                hints: [(label: String, keys: [String])] = [], @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.hints = hints
        self.actions = actions()
    }

    public var body: some View {
        VStack(spacing: RKSpacing.s3) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.rk(.textTertiary))
                .accessibilityHidden(true)
            Text(title).rkTypography(.title3).foregroundStyle(.rk(.textPrimary))
            if let message {
                Text(message).rkTypography(.body).foregroundStyle(.rk(.textSecondary)).multilineTextAlignment(.center)
            }
            HStack(spacing: RKSpacing.s2) { actions }
            if !hints.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: RKSpacing.s4, verticalSpacing: RKSpacing.s2) {
                    ForEach(hints.indices, id: \.self) { index in
                        GridRow {
                            Text(hints[index].label).rkTypography(.body).foregroundStyle(.rk(.textSecondary))
                            HStack(spacing: RKSpacing.half) {
                                ForEach(hints[index].keys, id: \.self) { RKKeyChip($0) }
                            }
                        }
                    }
                }
                .padding(.top, RKSpacing.s2)
            }
        }
        .padding(RKSpacing.s6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
    }
}

extension RKEmptyState where Actions == EmptyView {
    public init(_ title: String, message: String? = nil, systemImage: String = "tray",
                hints: [(label: String, keys: [String])] = []) {
        self.init(title, message: message, systemImage: systemImage, hints: hints) { EmptyView() }
    }
}
