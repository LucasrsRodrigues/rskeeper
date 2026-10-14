import Foundation
import Testing
@testable import RSKeeperFeatures

/// NST-05-01 — regras do layout de quatro regiões (W1-T17; doc 10 §3.2; SPK-N08).
@Suite("Layout do workspace (W1-T17)")
struct WorkspaceLayoutTests {
    @Test("Janela estreita (< 1.024 pt) recolhe a sidebar; conteúdo < 640 pt fecha o inspetor e avisa")
    func narrowRules() {
        #expect(WorkspaceLayout.decide(windowWidth: 1_440, contentWidth: 800, sidebarVisible: true, inspectorVisible: true) == .init())
        let narrow = WorkspaceLayout.decide(windowWidth: 1_000, contentWidth: 700, sidebarVisible: true, inspectorVisible: false)
        #expect(narrow.collapseSidebar && !narrow.collapseInspector)
        let tight = WorkspaceLayout.decide(windowWidth: 1_200, contentWidth: 600, sidebarVisible: true, inspectorVisible: true)
        #expect(tight.collapseInspector && tight.inspectorAutoClosed && !tight.collapseSidebar)
        // Nunca reabre sozinho o que o usuário fechou.
        #expect(WorkspaceLayout.decide(windowWidth: 2_000, contentWidth: 1_500, sidebarVisible: false, inspectorVisible: false) == .init())
    }

    @Test("Limites do SPK-N08 e janela mínima que comporta tudo no mínimo")
    func limits() {
        #expect(WorkspaceLayout.sidebar.min == 180 && WorkspaceLayout.sidebar.max == 420)
        #expect(WorkspaceLayout.inspector.min == 240 && WorkspaceLayout.inspector.max == 520)
        let allAtMinimum = WorkspaceLayout.railWidth + WorkspaceLayout.sidebar.min + WorkspaceLayout.contentMin + WorkspaceLayout.inspector.min
        #expect(allAtMinimum <= 868, "doc 10 §3.2: 868 pt com tudo no mínimo")
        #expect(WorkspaceLayout.minimumWindow.width >= 868)
    }

    @Test("Persistência por janela: nomes de autosave distintos")
    func autosavePerWindow() {
        let a = UUID(), b = UUID()
        #expect(WorkspaceLayout.autosaveName(window: a) != WorkspaceLayout.autosaveName(window: b))
        #expect(WorkspaceLayout.autosaveName(window: a) == WorkspaceLayout.autosaveName(window: a))
    }
}
