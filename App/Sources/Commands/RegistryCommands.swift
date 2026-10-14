import RSKeeperApplication
import SwiftUI

extension FocusedValues {
    /// Destino dos comandos da janela focada (doc 10 §5.2). Sem valor: só comandos globais habilitados.
    @Entry var commandTarget: CommandTarget?
}

/// Caixa observável para publicar o destino com `focusedSceneValue` (o protocolo é de classe e MainActor).
@MainActor
struct CommandTarget {
    let performer: any CommandPerforming
}

/// Menus gerados do `CommandRegistry` (NST-13-01): um item por definição, com atalho e habilitação vindos
/// do registro. Os atalhos alternativos (F5, ⇧F5) ficam com as views AppKit do editor (W1-T21), que
/// repassam `performKeyEquivalent` ao mesmo registro.
struct RegistryCommands: Commands {
    @FocusedValue(\.commandTarget) private var target
    @Environment(\.openWindow) private var openWindow

    private var context: CommandContext { target?.performer.commandContext ?? .none }

    var body: some Commands {
        CommandGroup(after: .newItem) {
            ForEach(CommandRegistry.commands(in: .file), id: \.id) { item($0) }
        }
        CommandMenu("Query") {
            ForEach(CommandRegistry.commands(in: .query), id: \.id) { item($0) }
        }
        CommandMenu("Data") {
            ForEach(CommandRegistry.commands(in: .data), id: \.id) { item($0) }
        }
        CommandGroup(after: .sidebar) {
            ForEach(CommandRegistry.commands(in: .view), id: \.id) { item($0) }
        }
        CommandGroup(after: .help) {
            ForEach(CommandRegistry.commands(in: .help), id: \.id) { item($0) }
        }
    }

    @ViewBuilder
    private func item(_ definition: CommandDefinition) -> some View {
        let button = Button(LocalizedStringKey(definition.title)) { perform(definition.id) }
            .disabled(!definition.isEnabled(context))
        if let shortcut = definition.shortcut {
            button.keyboardShortcut(shortcut.keyEquivalent, modifiers: shortcut.eventModifiers)
        } else {
            button
        }
    }

    private func perform(_ id: CommandID) {
        switch id {
        case CommandRegistry.newConnection: openWindow(id: SceneID.connections)
        default: target?.performer.perform(id)
        }
    }
}

extension KeyShortcut {
    /// Conversão para SwiftUI. Teclas de função usam os códigos de `NSEvent` (U+F704 = F1).
    var keyEquivalent: KeyEquivalent {
        switch key {
        case .character(let character): KeyEquivalent(character)
        case .return: .return
        case .tab: .tab
        case .escape: .escape
        case .delete: .delete
        case .leftArrow: .leftArrow
        case .rightArrow: .rightArrow
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .function(let n): KeyEquivalent(Character(UnicodeScalar(0xF704 + UInt32(n - 1))!))
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }
}
