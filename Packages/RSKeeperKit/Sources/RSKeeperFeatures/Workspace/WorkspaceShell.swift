import RSKeeperDesignSystem
import SwiftUI

/// Shell de quatro regiões (NST-05-01; doc 10 §3): trilho global (40 pt, fora do split) + sidebar,
/// conteúdo e inspetor no `NSSplitViewController` + barra de status embaixo.
public struct WorkspaceShell<Sidebar: View, Content: View, Inspector: View, Status: View>: View {
    @Bindable private var model: WorkspaceModel
    private let sidebar: Sidebar
    private let content: Content
    private let inspector: Inspector
    private let status: Status

    public init(model: WorkspaceModel, @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder content: () -> Content,
                @ViewBuilder inspector: () -> Inspector, @ViewBuilder status: () -> Status) {
        self.model = model
        self.sidebar = sidebar()
        self.content = content()
        self.inspector = inspector()
        self.status = status()
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                WorkspaceRail(model: model)
                    .frame(width: WorkspaceLayout.railWidth)
                    .background(Color.rk(.surfaceSidebar))
                Divider()
                WorkspaceSplit(model: model, sidebar: sidebar, content: content, inspector: inspector)
            }
            Divider()
            status
        }
        .frame(minWidth: WorkspaceLayout.minimumWindow.width, minHeight: WorkspaceLayout.minimumWindow.height)
    }
}

/// Trilho global (CAP-04): Explorador, Consultas salvas e Histórico. Os dois últimos chegam na onda 2.
struct WorkspaceRail: View {
    @Bindable var model: WorkspaceModel

    var body: some View {
        VStack(spacing: RKSpacing.s2) {
            item(.explorer, "cylinder.split.1x2", String(localized: "Explorer"), enabled: true)
            item(.savedQueries, "doc.text", String(localized: "Saved Queries"), enabled: false)
            item(.history, "clock.arrow.circlepath", String(localized: "History"), enabled: false)
            Spacer()
        }
        .padding(.top, RKSpacing.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("rk.workspace.rail")
    }

    private func item(_ destination: WorkspaceModel.RailDestination, _ symbol: String, _ title: String, enabled: Bool) -> some View {
        Button {
            if model.railDestination == destination { model.toggleSidebar() } else { model.railDestination = destination }
        } label: {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .foregroundStyle(.rk(model.railDestination == destination ? .accent : .textSecondary))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(title)
        .accessibilityLabel(Text(title))
        .accessibilityIdentifier("rk.workspace.rail.\(destination.rawValue)")
    }
}

/// Ponte SwiftUI → `WorkspaceSplitController`. O controlador é criado uma vez por janela.
struct WorkspaceSplit<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    let model: WorkspaceModel
    let sidebar: Sidebar
    let content: Content
    let inspector: Inspector

    func makeNSViewController(context: Context) -> WorkspaceSplitController {
        let controller = WorkspaceSplitController(sidebar: sidebar, content: content, inspector: inspector,
                                                  autosaveName: model.autosaveName)
        model.attach(controller)
        return controller
    }

    func updateNSViewController(_ controller: WorkspaceSplitController, context: Context) {
        controller.update(sidebar: sidebar, content: content, inspector: inspector)
    }
}
