import RSKeeperDesignSystem
import RSKeeperDomain
import SwiftUI

/// Barra de status única (NST-05-03; SCR-WS-07; CAP-04/08/09): botão da conexão à esquerda (cor, nome,
/// driver, ambiente em texto) e status da aba ativa à direita.
public struct WorkspaceStatusBar: View {
    @Bindable private var model: WorkspaceModel
    private let switchConnection: () -> Void

    public init(model: WorkspaceModel, switchConnection: @escaping () -> Void) {
        self.model = model
        self.switchConnection = switchConnection
    }

    public var body: some View {
        HStack(spacing: RKSpacing.s2) {
            Menu {
                // [CONFIRMADO, S3] Desconectar e Trocar conexão; ordem e aparência [DECISÃO] (menu não capturado).
                Button(String(localized: "Disconnect")) { Task { await model.disconnect() } }
                    .disabled(model.session == nil)
                    .accessibilityIdentifier("rk.status.disconnect")
                Button(String(localized: "Switch Connection…")) { switchConnection() }
                    .accessibilityIdentifier("rk.status.switch")
            } label: {
                HStack(spacing: RKSpacing.s1) {
                    Circle().fill(Color.rk(model.labelColor.token)).frame(width: 8, height: 8).accessibilityHidden(true)
                    Text(model.title).rkTypography(.caption).fontWeight(.semibold)
                    if let driver = model.driverName {
                        Text("· \(driver)").rkTypography(.caption).foregroundStyle(.rk(.textSecondary))
                    }
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            // VoiceOver lê nome, driver e ambiente (o SwiftUI usaria só o primeiro texto do rótulo).
            .accessibilityLabel(Text([model.title, model.driverName, model.environment?.shortLabel].compactMap { $0 }.joined(separator: ", ")))
            .accessibilityIdentifier("rk.status.connection")
            // O ambiente aparece em texto ao lado da cor (crit. 3; RF-CONN-16), nunca só como cor.
            if let environment = model.environment {
                RKBadge(environment.shortLabel, tone: environment == .production ? .danger : .neutral, outlined: environment == .production)
                    .accessibilityIdentifier("rk.status.environment")
            }
            if model.session == nil {
                Text(String(localized: "Disconnected")).rkTypography(.caption).foregroundStyle(.rk(.warning))
                    .accessibilityIdentifier("rk.status.disconnected")
            }
            Spacer()
            Text(model.notice ?? model.tabStatus ?? "").rkTypography(.caption).foregroundStyle(.rk(.textSecondary))
                .lineLimit(1)
                .accessibilityIdentifier("rk.status.tab")
        }
        .padding(.horizontal, RKSpacing.s2)
        .frame(height: 26)
        .background(Color.rk(.surfaceWindow))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rk.workspace.status")
    }
}

extension EnvironmentKind {
    /// Rótulo curto do ambiente (texto, para não depender só da cor).
    public var shortLabel: String {
        switch self {
        case .local: String(localized: "LOCAL")
        case .development: String(localized: "DEV")
        case .testing: String(localized: "TEST")
        case .staging: String(localized: "STAGING")
        case .production: String(localized: "PROD")
        case .custom: String(localized: "CUSTOM")
        }
    }
}
