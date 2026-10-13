import Foundation
import RSKeeperDomain

/// Redação de segredos em textos livres (W0-T14; NT-UNIT-12; docs/native/06).
///
/// Mascara: pares `chave=valor`/`chave: valor` de senhas, passphrases, tokens e segredos; credenciais
/// em URLs (`scheme://user:senha@host`); cabeçalhos `Bearer`; e valores conhecidos (canários, segredos
/// carregados na sessão) passados explicitamente.
public struct Redactor: Sendable {
    public static let mask = "•••"

    private let knownSecrets: [String]

    /// - Parameter knownSecrets: valores exatos a mascarar onde aparecerem (ex.: senhas em memória).
    public init(knownSecrets: [String] = []) {
        self.knownSecrets = knownSecrets.filter { $0.count >= 3 }
    }

    private static let keyValue = try! NSRegularExpression(
        pattern: #"(?i)\b(password|passwd|pwd|passphrase|secret|token|api[_-]?key|access[_-]?key|auth)\b(\s*[=:]\s*)("[^"]*"|'[^']*'|[^\s,;&"']+)"#)
    private static let urlCredential = try! NSRegularExpression(
        pattern: #"(?i)\b([a-z][a-z0-9+.\-]*://[^/\s:@]+):([^@/\s]+)@"#)
    private static let bearer = try! NSRegularExpression(pattern: #"(?i)\b(bearer)\s+[A-Za-z0-9._~+/=\-]+"#)
    private static let sqlPassword = try! NSRegularExpression(
        pattern: #"(?i)\b(identified\s+by|password)\s+('[^']*'|"[^"]*")"#)

    /// Texto com segredos mascarados.
    public func redact(_ text: String) -> String {
        var result = text
        for secret in knownSecrets where !secret.isEmpty {
            result = result.replacingOccurrences(of: secret, with: Self.mask)
        }
        result = Self.replace(Self.urlCredential, in: result, template: "$1:\(Self.mask)@")
        result = Self.replace(Self.sqlPassword, in: result, template: "$1 '\(Self.mask)'")
        result = Self.replace(Self.keyValue, in: result, template: "$1$2\(Self.mask)")
        result = Self.replace(Self.bearer, in: result, template: "$1 \(Self.mask)")
        return result
    }

    /// Converte em `RedactedMessage` (o único jeito de produzir mensagens exibíveis a partir de texto cru).
    public func message(_ text: String) -> RedactedMessage {
        RedactedMessage(alreadyRedacted: redact(text))
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, template: String) -> String {
        regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }
}
