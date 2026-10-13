import Foundation

/// Política de abertura de URLs externas (W0-T21, aceite 4): só `https:` e `mailto:`.
/// Esquemas como `file:`, `http:`, `javascript:`, `ssh:` e esquemas de app são recusados.
public enum ExternalURLPolicy {
    public static let allowedSchemes: Set<String> = ["https", "mailto"]

    public static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        if scheme == "https" {
            guard let host = url.host, !host.isEmpty else { return false }
            guard url.user == nil, url.password == nil else { return false }   // sem credencial embutida
        }
        return true
    }

    public static func isAllowed(_ string: String) -> Bool {
        guard let url = URL(string: string) else { return false }
        return isAllowed(url)
    }
}
