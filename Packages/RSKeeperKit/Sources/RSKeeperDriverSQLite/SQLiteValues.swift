import Foundation
import GRDB
import RSKeeperDomain
import RSKeeperDriversCore

/// Tipo declarado de uma coluna e o tipo portável derivado pelas regras de afinidade do SQLite.
struct SQLiteColumnKind: Sendable {
    let declaredType: String
    let portableType: PortableType

    init(declaredType: String?) {
        let declared = declaredType ?? ""
        self.declaredType = declared
        let upper = declared.uppercased()
        self.portableType =
            if upper.isEmpty { .unknown }                                     // expressão, sem tipo declarado
            else if upper.contains("BOOL") { .bool }
            else if upper.contains("JSON") { .json }
            else if upper.contains("DATETIME") || upper.contains("TIMESTAMP") { .timestamp }
            else if upper.contains("DATE") { .date }
            else if upper.contains("TIME") { .time }
            else if upper.contains("INT") { .bigint }                         // afinidade INTEGER (64 bits)
            else if upper.contains("CHAR") || upper.contains("CLOB") || upper.contains("TEXT") { .text }
            else if upper.contains("BLOB") { .bytes }
            else if upper.contains("REAL") || upper.contains("FLOA") || upper.contains("DOUB") { .double }
            else if upper.contains("DEC") || upper.contains("NUMERIC") { .decimal }
            else { .unknown }
    }
}

enum SQLiteValues {
    /// Valor armazenado + tipo declarado → `CellValue` (doc 04 §11). Nada passa por conversão silenciosa:
    /// datas ficam como o texto armazenado; inteiros em `Int64`; texto acima do limite vira `.truncated`.
    static func cell(_ value: DatabaseValue, kind: SQLiteColumnKind, maxCellBytes: Int) -> CellValue {
        switch value.storage {
        case .null:
            return .null
        case .int64(let int):
            return kind.portableType == .bool && (int == 0 || int == 1) ? .bool(int == 1) : .int(int)
        case .double(let double):
            return .double(double)
        case .string(let string):
            switch kind.portableType {
            case .json where string.utf8.count <= maxCellBytes: return .json(string)
            case .date: return .date(string)
            case .time: return .time(string)
            case .timestamp: return .timestamp(string, timeZone: nil)
            default: return .text(string, limit: maxCellBytes)
            }
        case .blob(let data):
            return .bytes(preview: Array(data.prefix(min(CellValueLimits.bytesPreviewMax, maxCellBytes))), totalSize: data.count)
        }
    }
}

/// Códigos do SQLite → `DriverError` (doc 04 §2.5). A mensagem é redigida: conteúdo entre aspas
/// simples (valores do usuário) é removido; o SQL nunca entra no erro.
enum SQLiteErrors {
    static func map(_ error: any Error) -> DriverError {
        switch error {
        case let error as DriverError:
            return error
        case is CancellationError:
            return .cancelled
        case let error as DatabaseError:
            let message = RedactedMessage(alreadyRedacted: redact(error.message ?? "Erro do SQLite."))
            switch error.resultCode {
            case .SQLITE_INTERRUPT: return .cancelled
            case .SQLITE_READONLY: return .readOnly
            case .SQLITE_BUSY, .SQLITE_LOCKED: return .busy
            case .SQLITE_CONSTRAINT: return .constraint(message)
            case .SQLITE_ERROR: return .syntaxOrSemantic(message, position: nil)
            case .SQLITE_CANTOPEN, .SQLITE_NOTADB, .SQLITE_CORRUPT:
                return .connection(message)
            case .SQLITE_AUTH, .SQLITE_PERM: return .readOnly
            default: return .driver(code: "SQLITE_\(error.extendedResultCode.rawValue)", message)
            }
        default:
            return .normalized(error)
        }
    }

    /// Remove o conteúdo de literais `'…'` da mensagem nativa.
    static func redact(_ message: String) -> String {
        var result = ""
        var insideLiteral = false
        for character in message {
            if character == "'" {
                result.append(character)
                if !insideLiteral { result.append("…") }
                insideLiteral.toggle()
            } else if !insideLiteral {
                result.append(character)
            }
        }
        return result
    }
}
