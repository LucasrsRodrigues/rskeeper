import SwiftUI

/// Chip de tecla (07 §8.8; [CONFIRMADO CAP-04] teclas em destaque na lista de atalhos).
public struct RKKeyChip: View {
    private let key: String
    public init(_ key: String) { self.key = key }

    public var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.rk(.textSecondary))
            .padding(.horizontal, RKSpacing.s1 + 1)
            .frame(minWidth: 18, minHeight: 18)
            .background(Color.rk(.surfaceRaised), in: RoundedRectangle(cornerRadius: RKRadius.small))
            .overlay { RoundedRectangle(cornerRadius: RKRadius.small).strokeBorder(Color.rk(.separatorStrong), lineWidth: 1) }
            .accessibilityLabel(Text(Self.spokenName(for: key)))
    }

    /// Nome falado da tecla para o VoiceOver (símbolos ⌘ ⇧ ⌥ ⌃ ↩ não são lidos de forma útil).
    public static func spokenName(for key: String) -> String {
        switch key {
        case "⌘": String(localized: "Command", bundle: .module)
        case "⇧": String(localized: "Shift", bundle: .module)
        case "⌥": String(localized: "Option", bundle: .module)
        case "⌃": String(localized: "Control", bundle: .module)
        case "↩": String(localized: "Return", bundle: .module)
        case "⎋": String(localized: "Escape", bundle: .module)
        default: key
        }
    }
}

/// Controle segmentado compacto, 2–4 opções (07 §8.2; [CONFIRMADO CAP-04] "Auto Commit | Manual").
/// Muda com ←/→ quando focado (comportamento do controle nativo).
public struct RKSegmentedControl<Value: Hashable>: View {
    private let title: String
    @Binding private var selection: Value
    private let options: [(value: Value, label: String)]

    public init(_ title: String, selection: Binding<Value>, options: [(value: Value, label: String)]) {
        precondition((2...4).contains(options.count), "RKSegmentedControl aceita de 2 a 4 opções")
        self.title = title
        self._selection = selection
        self.options = options
    }

    public var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                Text(options[index].label).tag(options[index].value)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel(Text(title))
    }
}

/// Banner dentro do painel afetado: não rouba foco, ação opcional, fechável (07 §8.11).
public struct RKInlineBanner: View {
    public enum Kind: Sendable, CaseIterable { case info, success, warning, error }

    private let kind: Kind
    private let message: String
    private let actionTitle: String?
    private let action: (() -> Void)?
    private let onDismiss: (() -> Void)?

    public init(_ kind: Kind, message: String, actionTitle: String? = nil, action: (() -> Void)? = nil,
                onDismiss: (() -> Void)? = nil) {
        self.kind = kind
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
        self.onDismiss = onDismiss
    }

    public var body: some View {
        HStack(spacing: RKSpacing.s2) {
            Image(systemName: icon).foregroundStyle(tint).accessibilityHidden(true)
            Text(message).rkTypography(.body).foregroundStyle(.rk(.textPrimary)).frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.rk(.secondary))
            }
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.rk(.ghost))
                    .accessibilityLabel(Text(String(localized: "Dismiss", bundle: .module)))
            }
        }
        .padding(RKSpacing.s2)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: RKRadius.control))
        .overlay { RoundedRectangle(cornerRadius: RKRadius.control).strokeBorder(tint.opacity(0.5), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(kindName): \(message)"))
    }

    private var kindName: String {
        switch kind {
        case .info: String(localized: "Information", bundle: .module)
        case .success: String(localized: "Success", bundle: .module)
        case .warning: String(localized: "Warning", bundle: .module)
        case .error: String(localized: "Error", bundle: .module)
        }
    }

    private var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch kind {
        case .info: .rk(.info)
        case .success: .rk(.success)
        case .warning: .rk(.warning)
        case .error: .rk(.danger)
        }
    }
}

/// Toast breve: não recebe foco, some sozinho e é anunciado ao VoiceOver (07 §8.12).
public struct RKToast: View {
    /// Tempo de exibição [META 4 s].
    public static let displayDuration: Duration = .seconds(4)

    private let message: String
    public init(_ message: String) { self.message = message }

    public var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .rkTypography(.body)
            .foregroundStyle(.rk(.textPrimary))
            .padding(.horizontal, RKSpacing.s3)
            .padding(.vertical, RKSpacing.s2)
            .background(Color.rk(.surfaceOverlay), in: RoundedRectangle(cornerRadius: RKRadius.card))
            .overlay { RoundedRectangle(cornerRadius: RKRadius.card).strokeBorder(Color.rk(.separator), lineWidth: 1) }
            .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
            .focusable(false)
            .accessibilityAddTraits(.isStaticText)
            .onAppear {
                AccessibilityNotification.Announcement(message).post()
            }
    }
}
