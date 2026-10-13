import AppKit
import SwiftUI
import Testing
@testable import RSKeeperDesignSystem

/// Paleta de tokens para o snapshot.
private struct PaletteView: View {
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(28), spacing: 4), count: 13), spacing: 4) {
            ForEach(RKColorToken.allCases, id: \.self) { token in
                RoundedRectangle(cornerRadius: 3).fill(Color.rk(token)).frame(width: 28, height: 28)
            }
        }
        .padding(8)
        .background(Color.rk(.surfaceWindow))
    }
}

private struct ControlsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(RKButtonVariant.allCases, id: \.self) { Button("Button") {}.buttonStyle(RKButtonStyle($0)) }
            }
            HStack(spacing: 8) {
                ForEach(RKBadge.Tone.allCases, id: \.self) { RKBadge("BADGE", tone: $0) }
                RKBadge("PROD", tone: .danger, outlined: true)
                RKCounterBadge(42)
            }
            HStack(spacing: 4) { RKKeyChip("⌘"); RKKeyChip("⇧"); RKKeyChip("↩"); RKKeyChip("F5") }
            RKProgress(fraction: 0.5).frame(width: 200)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.rk(.surfaceWindow))
    }
}

private struct PatternsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(RKInlineBanner.Kind.allCases, id: \.self) { RKInlineBanner($0, message: "Message") }
            RKToast("Saved")
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.rk(.surfaceWindow))
    }
}

@Suite("Componentes básicos (W0-T26/T27)")
@MainActor
struct ComponentLogicTests {
    @Test("Rótulo dinâmico do botão de execução [CONFIRMADO CAP-04/08]")
    func runModeLabel() {
        #expect(RunMode.effective(hasSelection: true, preferred: .all) == .selection)
        #expect(RunMode.effective(hasSelection: false, preferred: .all) == .all)
        #expect(RunMode.effective(hasSelection: false, preferred: .current) == .current)
        #expect(RunMode.effective(hasSelection: false, preferred: .selection) == .all)
        #expect(Set(RunMode.allCases.map(\.label)).count == 3)
    }

    @Test("Chips de tecla têm nome falado para o VoiceOver")
    func keyChipSpokenNames() {
        #expect(RKKeyChip.spokenName(for: "⌘") == "Command")
        #expect(RKKeyChip.spokenName(for: "↩") == "Return")
        #expect(RKKeyChip.spokenName(for: "F5") == "F5")
    }

    @Test("Toast some em 4 s [META]")
    func toastDuration() { #expect(RKToast.displayDuration == .seconds(4)) }

    @Test("Componentes renderizam com tamanho não nulo nos modos claro e escuro")
    @MainActor
    func componentsRender() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for (name, view) in [("controls", AnyView(ControlsView())), ("patterns", AnyView(PatternsView())),
                                 ("gallery", AnyView(ComponentGallery()))] {
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                host.frame = CGRect(x: 0, y: 0, width: 700, height: 500)
                host.layoutSubtreeIfNeeded()
                #expect(host.fittingSize.width > 0 && host.fittingSize.height > 0, "\(name) [\(appearance.rawValue)]")
            }
        }
    }
}

/// NT-SNAP-01 — paleta e componentes em claro e escuro.
@Suite("Snapshots (NT-SNAP-01)", .serialized)
@MainActor
struct SnapshotTests {
    @Test("Paleta de tokens", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func palette(appearance: NSAppearance.Name) throws {
        try Snapshot.assert(PaletteView(), named: "palette-\(Self.suffix(appearance))", size: CGSize(width: 440, height: 150), appearance: appearance)
    }

    @Test("Controles", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func controls(appearance: NSAppearance.Name) throws {
        try Snapshot.assert(ControlsView(), named: "controls-\(Self.suffix(appearance))", size: CGSize(width: 560, height: 160), appearance: appearance)
    }

    @Test("Padrões (banners e toast)", arguments: [NSAppearance.Name.aqua, .darkAqua])
    func patterns(appearance: NSAppearance.Name) throws {
        try Snapshot.assert(PatternsView(), named: "patterns-\(Self.suffix(appearance))", size: CGSize(width: 420, height: 250), appearance: appearance)
    }

    @Test("O comparador detecta mudança visual (sensibilidade)")
    func comparatorDetectsChanges() throws {
        let size = CGSize(width: 420, height: 250)
        let a = try #require(NSBitmapImageRep(data: Snapshot.render(PatternsView(), size: size, appearance: .darkAqua).representation(using: .png, properties: [:])!))
        let b = try #require(NSBitmapImageRep(data: Snapshot.render(PatternsView(), size: size, appearance: .aqua).representation(using: .png, properties: [:])!))
        let same = try #require(NSBitmapImageRep(data: Snapshot.render(PatternsView(), size: size, appearance: .darkAqua).representation(using: .png, properties: [:])!))
        #expect(Snapshot.difference(a, b) > 0.005, "claro × escuro precisa divergir")
        #expect(Snapshot.difference(a, same) <= 0.005, "mesma view precisa coincidir")
    }

    private static func suffix(_ appearance: NSAppearance.Name) -> String { appearance == .darkAqua ? "dark" : "light" }
}
