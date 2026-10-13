import SwiftUI

/// Galeria de componentes e estados (W0-T27, aceite 2). Aberta só no build Dev (comando de depuração).
public struct ComponentGallery: View {
    @State private var text = ""
    @State private var invalid = "porta 0"
    @State private var search = "orders"
    @State private var mode = "auto"
    @State private var toggle = true

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RKSpacing.s6) {
                section("Buttons") {
                    HStack(spacing: RKSpacing.s2) {
                        ForEach(RKButtonVariant.allCases, id: \.self) { variant in
                            Button(String(describing: variant)) {}.buttonStyle(RKButtonStyle(variant))
                        }
                        Button("Loading") {}.buttonStyle(RKButtonStyle(.primary, isLoading: true))
                        Button("Disabled") {}.buttonStyle(RKButtonStyle(.secondary)).disabled(true)
                    }
                    HStack(spacing: RKSpacing.s2) {
                        ForEach(RunMode.allCases, id: \.self) { mode in
                            RKSplitButton(mode.label, action: {}) {
                                Button(RunMode.current.label) {}
                                Button(RunMode.all.label) {}
                            }
                        }
                    }
                }
                section("Fields") {
                    RKTextField("Host", text: $text, monospaced: true)
                    RKTextField("Port", text: $invalid, monospaced: true, error: String(localized: "Port must be between 1 and 65535", bundle: .module))
                    RKSearchField(String(localized: "Filter", bundle: .module), text: $search)
                    Toggle("SSL", isOn: $toggle).toggleStyle(.switch)
                }
                section("Segmented, badges and keys") {
                    RKSegmentedControl("Transaction mode", selection: $mode,
                                       options: [("auto", "Auto Commit"), ("manual", "Manual")])
                    HStack {
                        ForEach(RKBadge.Tone.allCases, id: \.self) { RKBadge(String(describing: $0), tone: $0) }
                        RKBadge("PROD", tone: .danger, outlined: true)
                        RKCounterBadge(128)
                    }
                    HStack { RKKeyChip("⌘"); RKKeyChip("⇧"); RKKeyChip("↩"); RKKeyChip("F5") }
                }
                section("Feedback") {
                    ForEach(RKInlineBanner.Kind.allCases, id: \.self) { kind in
                        RKInlineBanner(kind, message: String(describing: kind), actionTitle: "Action", action: {}, onDismiss: {})
                    }
                    RKToast("Saved")
                    RKProgress(fraction: 0.42).frame(width: 240)
                    RKProgress()
                }
                section("Empty state") {
                    RKEmptyState("No results", message: "Run a query to see results here.",
                                 hints: [("Run All", ["⌘", "↩"]), ("Run Current", ["⌘", "⇧", "↩"])])
                        .frame(height: 260)
                }
            }
            .padding(RKSpacing.s6)
        }
        .background(Color.rk(.surfaceWindow))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: RKSpacing.s3) {
            Text(title.uppercased()).rkTypography(.section).foregroundStyle(.rk(.textSecondary))
            content()
        }
    }
}
