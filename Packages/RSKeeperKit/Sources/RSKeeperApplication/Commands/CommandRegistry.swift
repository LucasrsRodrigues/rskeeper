import RSKeeperDomain

/// Identificador estável de comando (`query.runAll`).
public struct CommandID: RawRepresentable, Hashable, Sendable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
}

/// Atalho independente de UI (o app converte para `KeyEquivalent`/`NSMenuItem`).
public struct KeyShortcut: Hashable, Sendable, CustomStringConvertible {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case `return`, tab, escape, delete, leftArrow, rightArrow, upArrow, downArrow
        case function(Int)
    }
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let command = Modifiers(rawValue: 1)
        public static let shift = Modifiers(rawValue: 2)
        public static let option = Modifiers(rawValue: 4)
        public static let control = Modifiers(rawValue: 8)
    }

    public let key: Key
    public let modifiers: Modifiers

    public init(_ key: Key, _ modifiers: Modifiers = []) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Texto como o macOS mostra (⌃⌥⇧⌘ nessa ordem), também usado nos chips do estado vazio.
    public var symbols: [String] {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        switch key {
        case .character(let character): parts.append(character == " " ? "Espaço" : String(character).uppercased())
        case .return: parts.append("↩")
        case .tab: parts.append("⇥")
        case .escape: parts.append("⎋")
        case .delete: parts.append("⌫")
        case .leftArrow: parts.append("←")
        case .rightArrow: parts.append("→")
        case .upArrow: parts.append("↑")
        case .downArrow: parts.append("↓")
        case .function(let n): parts.append("F\(n)")
        }
        return parts
    }

    public var description: String { symbols.joined() }
}

/// Estado da janela e da aba ativas, de que dependem as regras de habilitação.
public struct CommandContext: Hashable, Sendable {
    public enum ActiveTab: Hashable, Sendable { case none, query, table }

    public var isConnected = false
    public var activeTab: ActiveTab = .none
    public var hasSelection = false
    public var hasCurrentStatement = false
    public var isRunning = false
    public var canPageForward = false
    public var canPageBackward = false
    public var isWorkspace = false

    public init(isConnected: Bool = false, activeTab: ActiveTab = .none, hasSelection: Bool = false, hasCurrentStatement: Bool = false,
                isRunning: Bool = false, canPageForward: Bool = false, canPageBackward: Bool = false, isWorkspace: Bool = false) {
        self.isConnected = isConnected
        self.activeTab = activeTab
        self.hasSelection = hasSelection
        self.hasCurrentStatement = hasCurrentStatement
        self.isRunning = isRunning
        self.canPageForward = canPageForward
        self.canPageBackward = canPageBackward
        self.isWorkspace = isWorkspace
    }

    /// Sem janela focada (ou janela sem contexto): tudo que depende de conexão fica desabilitado.
    public static let none = CommandContext()
}

/// Menu em que o comando aparece (doc 10 §5.3).
public enum CommandMenuGroup: String, Sendable, CaseIterable {
    case file, query, data, view, help
}

/// Definição única de um comando (doc 10 §5.1): menus, atalhos, menus contextuais e paleta leem daqui.
public struct CommandDefinition: Sendable, Identifiable {
    public let id: CommandID
    /// Chave de localização (texto em inglês; traduzido pelo String Catalog do app).
    public let title: String
    public let symbol: String?
    public let shortcut: KeyShortcut?
    /// Atalho alternativo herdado do original (F5, ⇧F5).
    public let alternateShortcut: KeyShortcut?
    public let menu: CommandMenuGroup
    public let isEnabled: @Sendable (CommandContext) -> Bool
}

/// Registro de comandos da onda 1 (NST-13-01; ADR-N13/N15).
public enum CommandRegistry {
    public static let newConnection: CommandID = "file.newConnection"
    public static let runAll: CommandID = "query.runAll"
    public static let runCurrent: CommandID = "query.runCurrent"
    public static let runSelection: CommandID = "query.runSelection"
    public static let cancel: CommandID = "query.cancel"
    public static let disconnect: CommandID = "connection.disconnect"
    public static let refresh: CommandID = "data.refresh"
    public static let nextPage: CommandID = "data.nextPage"
    public static let previousPage: CommandID = "data.previousPage"
    public static let toggleSidebar: CommandID = "view.toggleSidebar"
    public static let toggleInspector: CommandID = "view.toggleInspector"
    public static let nextRegion: CommandID = "view.nextRegion"
    public static let previousRegion: CommandID = "view.previousRegion"
    public static let keyboardShortcuts: CommandID = "help.keyboardShortcuts"

    public static let all: [CommandDefinition] = [
        .init(id: newConnection, title: "New Connection…", symbol: "plus", shortcut: .init(.character("n"), [.command, .shift]),
              alternateShortcut: nil, menu: .file, isEnabled: { _ in true }),
        .init(id: runAll, title: "Run All", symbol: "play.fill", shortcut: .init(.return, .command), alternateShortcut: .init(.function(5)),
              menu: .query, isEnabled: { $0.isConnected && $0.activeTab == .query && !$0.isRunning }),
        .init(id: runCurrent, title: "Run Current", symbol: "play", shortcut: .init(.return, [.command, .shift]),
              alternateShortcut: .init(.function(5), .shift), menu: .query,
              isEnabled: { $0.isConnected && $0.activeTab == .query && $0.hasCurrentStatement && !$0.isRunning }),
        .init(id: runSelection, title: "Run Selection", symbol: "play.square", shortcut: nil, alternateShortcut: nil, menu: .query,
              isEnabled: { $0.isConnected && $0.activeTab == .query && $0.hasSelection && !$0.isRunning }),
        .init(id: cancel, title: "Cancel Execution", symbol: "stop.fill", shortcut: .init(.character("."), .command), alternateShortcut: nil,
              menu: .query, isEnabled: { $0.isRunning }),
        .init(id: disconnect, title: "Disconnect", symbol: "bolt.slash", shortcut: nil, alternateShortcut: nil, menu: .file,
              isEnabled: { $0.isConnected }),
        .init(id: refresh, title: "Refresh", symbol: "arrow.clockwise", shortcut: .init(.character("r"), .command), alternateShortcut: nil,
              menu: .data, isEnabled: { $0.isConnected && !$0.isRunning }),
        .init(id: nextPage, title: "Next Page", symbol: "chevron.right", shortcut: .init(.rightArrow, [.command, .option]),
              alternateShortcut: nil, menu: .data, isEnabled: { $0.activeTab == .table && $0.canPageForward && !$0.isRunning }),
        .init(id: previousPage, title: "Previous Page", symbol: "chevron.left", shortcut: .init(.leftArrow, [.command, .option]),
              alternateShortcut: nil, menu: .data, isEnabled: { $0.activeTab == .table && $0.canPageBackward && !$0.isRunning }),
        .init(id: toggleSidebar, title: "Toggle Sidebar", symbol: "sidebar.left", shortcut: .init(.character("s"), [.command, .control]),
              alternateShortcut: nil, menu: .view, isEnabled: { $0.isWorkspace }),
        .init(id: toggleInspector, title: "Toggle Inspector", symbol: "sidebar.right", shortcut: .init(.character("i"), [.command, .option]),
              alternateShortcut: nil, menu: .view, isEnabled: { $0.isWorkspace }),
        .init(id: nextRegion, title: "Focus Next Region", symbol: nil, shortcut: .init(.function(6)), alternateShortcut: nil, menu: .view,
              isEnabled: { $0.isWorkspace }),
        .init(id: previousRegion, title: "Focus Previous Region", symbol: nil, shortcut: .init(.function(6), .shift), alternateShortcut: nil,
              menu: .view, isEnabled: { $0.isWorkspace }),
        .init(id: keyboardShortcuts, title: "Keyboard Shortcuts", symbol: "keyboard", shortcut: .init(.character("/"), .command),
              alternateShortcut: nil, menu: .help, isEnabled: { _ in true }),
    ]

    public static func definition(_ id: CommandID) -> CommandDefinition? { all.first { $0.id == id } }

    public static func commands(in menu: CommandMenuGroup) -> [CommandDefinition] { all.filter { $0.menu == menu } }

    /// Atalhos usados por mais de um comando (precisa ser vazio; também para a edição de atalhos).
    public static func shortcutConflicts() -> [KeyShortcut: [CommandID]] {
        var owners: [KeyShortcut: [CommandID]] = [:]
        for definition in all {
            for shortcut in [definition.shortcut, definition.alternateShortcut].compactMap({ $0 }) {
                owners[shortcut, default: []].append(definition.id)
            }
        }
        return owners.filter { $0.value.count > 1 }
    }
}

/// Destino dos comandos da janela focada (o app publica com `focusedSceneValue`).
@MainActor
public protocol CommandPerforming: AnyObject {
    var commandContext: CommandContext { get }
    func perform(_ command: CommandID)
}
