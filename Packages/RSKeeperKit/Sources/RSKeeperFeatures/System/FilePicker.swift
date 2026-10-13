import AppKit
import UniformTypeIdentifiers

/// Invólucro de `NSOpenPanel` (W0-T21). O caminho só entra no app por aqui; a URL devolvida
/// é convertida em concessão (`FileGrantService`) e nunca guardada crua.
@MainActor
public enum FilePicker {
    /// Abre o painel para um único arquivo. Retorna `nil` se o usuário cancelar.
    public static func chooseFile(title: String, allowedTypes: [UTType] = []) async -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        if !allowedTypes.isEmpty { panel.allowedContentTypes = allowedTypes }
        let response = await panel.begin()
        return response == .OK ? panel.url : nil
    }
}
