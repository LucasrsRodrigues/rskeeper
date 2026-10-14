import Foundation

/// Pasta de conexões da sidebar.
public struct ProfileFolder: Hashable, Sendable, Identifiable {
    public var id: FolderID
    public var name: String
    public var parentID: FolderID?
    public var position: Int
    public var expanded: Bool

    public init(id: FolderID = .generate(), name: String, parentID: FolderID? = nil, position: Int = 0, expanded: Bool = true) {
        self.id = id
        self.name = name
        self.parentID = parentID
        self.position = position
        self.expanded = expanded
    }
}

/// Conteúdo da sidebar de conexões (NST-03-01): fixadas, salvas (com pastas) e recentes.
public struct ConnectionSidebarContent: Hashable, Sendable {
    public var pinned: [ConnectionProfile]
    public var saved: [ConnectionProfile]
    public var recent: [ConnectionProfile]
    public var folders: [ProfileFolder]

    public init(pinned: [ConnectionProfile], saved: [ConnectionProfile], recent: [ConnectionProfile], folders: [ProfileFolder]) {
        self.pinned = pinned
        self.saved = saved
        self.recent = recent
        self.folders = folders
    }

    public static let empty = ConnectionSidebarContent(pinned: [], saved: [], recent: [], folders: [])
}

