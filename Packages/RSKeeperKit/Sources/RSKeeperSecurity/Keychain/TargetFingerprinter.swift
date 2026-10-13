import CryptoKit
import Foundation
import RSKeeperDomain

/// Impressão digital do alvo (porta DR-01; docs/native/03 §2.2):
/// SHA-256 de `driverID|host|port|user|sshHost|sshPort|sshUser`.
/// Mudar qualquer um desses campos sem novo segredo invalida os segredos armazenados.
public enum TargetFingerprinter {
    public static func fingerprint(of profile: ConnectionProfile) -> TargetFingerprint {
        var parts = [profile.driverID.rawValue]
        switch profile.target {
        case .file(let grant, _):
            parts += ["file", grant.id.uuidString]
        case .server(let host, let port, let user, _):
            parts += ["server", host.lowercased(), String(port), user ?? ""]
        }
        if let ssh = profile.ssh {
            parts += ["ssh", ssh.host.lowercased(), String(ssh.port), ssh.user]
        } else {
            parts += ["ssh", "", "", ""]
        }
        let joined = parts.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: "|")
        return TargetFingerprint(digest: Array(SHA256.hash(data: Data(joined.utf8))))
    }
}
