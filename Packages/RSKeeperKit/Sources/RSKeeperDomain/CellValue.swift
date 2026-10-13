import Foundation

/// Valor de célula portável entre drivers (docs/native/03 §4.4; NST-01-01 crit. 3; porta AR-MEM-05).
///
/// - `decimal`, inteiros fora de `Int64` e valores monetários guardam o **texto exato** do servidor
///   (nunca passam por `Double`).
/// - Datas e horas guardam o texto do servidor, sem conversão silenciosa de fuso.
public enum CellValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case decimal(String)
    case double(Double)
    case text(String)
    case bytes(preview: [UInt8], totalSize: Int)
    case date(String)
    case time(String)
    case timestamp(String, timeZone: String?)
    case json(String)
    case uuid(UUID)
    case array([CellValue])
    case truncated(prefix: String, totalSize: Int)
    case unsupported(typeName: String)
}

/// Limites de representação de valores [META, calibrados no SPK-N09].
public enum CellValueLimits {
    /// Prévia máxima de um valor binário.
    public static let bytesPreviewMax = 4 * 1024
    /// Tamanho máximo de um valor textual inline; acima disso, `.truncated`.
    public static let inlineTextMax = 64 * 1024
}

extension CellValue {
    /// Constrói um valor binário respeitando a prévia máxima.
    public static func binary(_ data: [UInt8]) -> CellValue {
        .bytes(preview: Array(data.prefix(CellValueLimits.bytesPreviewMax)), totalSize: data.count)
    }

    /// Constrói um valor textual, truncando acima do limite inline (sem cortar um caractere ao meio).
    public static func textValue(_ string: String) -> CellValue {
        let utf8Count = string.utf8.count
        guard utf8Count > CellValueLimits.inlineTextMax else { return .text(string) }
        var prefix = ""
        var used = 0
        for character in string {
            let size = character.utf8.count
            if used + size > CellValueLimits.inlineTextMax { break }
            prefix.append(character)
            used += size
        }
        return .truncated(prefix: prefix, totalSize: utf8Count)
    }

    /// Converte um inteiro textual do servidor: cabe em `Int64` → `.int`; senão, texto exato em `.decimal`.
    public static func integerText(_ text: String) -> CellValue {
        if let value = Int64(text) { return .int(value) }
        return .decimal(text)
    }

    /// Indica se o valor é nulo.
    public var isNull: Bool { if case .null = self { true } else { false } }
}
