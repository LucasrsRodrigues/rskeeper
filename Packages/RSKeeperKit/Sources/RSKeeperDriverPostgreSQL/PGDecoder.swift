import Foundation
import PostgresNIO
import RSKeeperDomain
import RSKeeperDriversCore

/// Informação de tipo do `pg_type`, carregada uma vez por conexão (enum, domínio de texto, nomes).
struct PGTypeCatalog: Sendable {
    struct Entry: Sendable {
        let name: String
        /// `typtype`: b base, e enum, d domínio, c composto, r range, p pseudo.
        let kind: Character
        /// `typcategory`: S string, A array, N numérico…
        let category: Character
        let elementOID: UInt32
    }
    let entries: [UInt32: Entry]

    func name(of oid: UInt32) -> String { entries[oid]?.name ?? PGDecoder.builtinNames[oid] ?? "oid \(oid)" }

    func portableType(of oid: UInt32) -> PortableType {
        if let builtin = PGDecoder.builtinPortable[oid] { return builtin }
        guard let entry = entries[oid] else { return .unknown }
        if entry.category == "A" { return .array }
        if entry.kind == "e" || entry.category == "S" { return .text }
        return .unknown
    }
}

/// Decodificador **binário** próprio (SPK-N03: os resultados vêm sempre em binário e os
/// decodificadores da biblioteca não servem para exibição). Nada passa por conversão silenciosa:
/// `numeric` vira texto exato; datas e horas ficam em texto ISO no fuso do servidor (UTC para `timestamptz`).
enum PGDecoder {
    static let builtinNames: [UInt32: String] = [
        16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text", 26: "oid",
        114: "json", 142: "xml", 650: "cidr", 700: "float4", 701: "float8", 705: "unknown", 790: "money", 829: "macaddr",
        869: "inet", 1042: "bpchar", 1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz",
        1186: "interval", 1266: "timetz", 1560: "bit", 1562: "varbit", 1700: "numeric", 2950: "uuid", 3802: "jsonb",
    ]

    static let builtinPortable: [UInt32: PortableType] = [
        16: .bool, 17: .bytes, 18: .text, 19: .text, 20: .bigint, 21: .int, 23: .int, 25: .text, 26: .bigint,
        114: .json, 142: .text, 650: .text, 700: .double, 701: .double, 705: .text, 790: .decimal, 829: .text,
        869: .text, 1042: .text, 1043: .text, 1082: .date, 1083: .time, 1114: .timestamp, 1184: .timestampTZ,
        1186: .interval, 1266: .time, 1560: .text, 1562: .text, 1700: .decimal, 2950: .uuid, 3802: .json,
    ]

    static func cell(_ bytes: ByteBuffer?, oid: UInt32, catalog: PGTypeCatalog, maxCellBytes: Int) -> CellValue {
        guard var buffer = bytes else { return .null }
        if let value = decode(&buffer, oid: oid, catalog: catalog, maxCellBytes: maxCellBytes) { return value }
        return .unsupported(typeName: catalog.name(of: oid))
    }

    private static func text(_ buffer: inout ByteBuffer, _ limit: Int) -> CellValue {
        .text(buffer.readString(length: buffer.readableBytes) ?? "", limit: limit)
    }

    /// `nil` = formato inesperado (vira `.unsupported`, nunca um valor errado).
    private static func decode(_ b: inout ByteBuffer, oid: UInt32, catalog: PGTypeCatalog, maxCellBytes: Int) -> CellValue? {
        switch oid {
        case 16: return b.readInteger(as: UInt8.self).map { .bool($0 != 0) }
        case 17:
            let size = b.readableBytes
            return .bytes(preview: b.readBytes(length: min(size, min(CellValueLimits.bytesPreviewMax, maxCellBytes))) ?? [], totalSize: size)
        case 18: return b.readInteger(as: UInt8.self).map { .text(String(UnicodeScalar($0))) }
        case 19, 25, 142, 705, 1042, 1043: return text(&b, maxCellBytes)
        case 20: return b.readInteger(as: Int64.self).map { .int($0) }
        case 21: return b.readInteger(as: Int16.self).map { .int(Int64($0)) }
        case 23: return b.readInteger(as: Int32.self).map { .int(Int64($0)) }
        case 26: return b.readInteger(as: UInt32.self).map { .int(Int64($0)) }
        case 700: return b.readInteger(as: UInt32.self).map { .double(Double(String(Float(bitPattern: $0))) ?? Double(Float(bitPattern: $0))) }
        case 701: return b.readInteger(as: UInt64.self).map { .double(Double(bitPattern: $0)) }
        case 790: return b.readInteger(as: Int64.self).map { .decimal(money($0)) }
        case 1700: return numeric(&b).map { .decimal($0) }
        case 114:
            let size = b.readableBytes
            let string = b.readString(length: size) ?? ""
            return size <= maxCellBytes ? .json(string) : .text(string, limit: maxCellBytes)
        case 3802:
            guard b.readInteger(as: UInt8.self) == 1 else { return nil }          // versão do jsonb
            let size = b.readableBytes
            let string = b.readString(length: size) ?? ""
            return size <= maxCellBytes ? .json(string) : .text(string, limit: maxCellBytes)
        case 2950:
            guard let raw = b.readBytes(length: 16) else { return nil }
            return .uuid(UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                                     raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15])))
        case 1082: return b.readInteger(as: Int32.self).map { .date(date($0)) }
        case 1083: return b.readInteger(as: Int64.self).map { .time(time($0)) }
        case 1266:
            guard let micros = b.readInteger(as: Int64.self), let zone = b.readInteger(as: Int32.self) else { return nil }
            return .time(time(micros) + offset(-Int(zone)))                      // o protocolo guarda o fuso a oeste como positivo
        case 1114: return b.readInteger(as: Int64.self).map { .timestamp(timestamp($0), timeZone: nil) }
        case 1184: return b.readInteger(as: Int64.self).map { .timestamp(timestamp($0), timeZone: "UTC") }
        case 1186:
            guard let micros = b.readInteger(as: Int64.self), let days = b.readInteger(as: Int32.self),
                  let months = b.readInteger(as: Int32.self) else { return nil }
            return .text(interval(micros: micros, days: days, months: months))
        case 869, 650: return inet(&b, cidr: oid == 650).map { .text($0) }
        case 829:
            guard let raw = b.readBytes(length: 6) else { return nil }
            return .text(raw.map { String(format: "%02x", $0) }.joined(separator: ":"))
        case 1560, 1562:
            guard let bitCount = b.readInteger(as: Int32.self) else { return nil }
            let raw = b.readBytes(length: b.readableBytes) ?? []
            return .text(String((0..<Int(bitCount)).map { raw[$0 / 8] & (0x80 >> UInt8($0 % 8)) != 0 ? "1" : "0" }))
        default:
            guard let entry = catalog.entries[oid] else { return nil }
            if entry.category == "A" { return array(&b, catalog: catalog, maxCellBytes: maxCellBytes) }
            // Enum e tipos da categoria string (citext…) chegam como texto no formato binário.
            if entry.kind == "e" || entry.category == "S" { return text(&b, maxCellBytes) }
            return nil
        }
    }

    // MARK: Arrays

    private static func array(_ b: inout ByteBuffer, catalog: PGTypeCatalog, maxCellBytes: Int) -> CellValue? {
        guard let dimensions = b.readInteger(as: Int32.self), b.readInteger(as: Int32.self) != nil,
              let elementOID = b.readInteger(as: UInt32.self) else { return nil }
        guard dimensions > 0 else { return .array([]) }
        var sizes: [Int] = []
        for _ in 0..<dimensions {
            guard let size = b.readInteger(as: Int32.self), b.readInteger(as: Int32.self) != nil else { return nil }
            sizes.append(Int(size))
        }
        func element() -> CellValue? {
            guard let length = b.readInteger(as: Int32.self) else { return nil }
            if length < 0 { return .null }
            guard var slice = b.readSlice(length: Int(length)) else { return nil }
            return decode(&slice, oid: elementOID, catalog: catalog, maxCellBytes: maxCellBytes) ?? .unsupported(typeName: catalog.name(of: elementOID))
        }
        func level(_ depth: Int) -> CellValue? {
            var values: [CellValue] = []
            for _ in 0..<sizes[depth] {
                guard let value = depth == sizes.count - 1 ? element() : level(depth + 1) else { return nil }
                values.append(value)
            }
            return .array(values)
        }
        return level(0)
    }

    // MARK: Numéricos

    /// `numeric` binário: dígitos em base 10.000 com peso e escala. Texto exato, sem `Double`.
    private static func numeric(_ b: inout ByteBuffer) -> String? {
        guard let count = b.readInteger(as: Int16.self), let weight = b.readInteger(as: Int16.self),
              let sign = b.readInteger(as: UInt16.self), let scale = b.readInteger(as: UInt16.self) else { return nil }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        var digits: [Int16] = []
        for _ in 0..<count {
            guard let digit = b.readInteger(as: Int16.self) else { return nil }
            digits.append(digit)
        }
        // Parte inteira: grupos 0…weight; fracionária: grupos depois, em 4 casas cada.
        var integer = ""
        if weight < 0 {
            integer = "0"
        } else {
            for index in 0...Int(weight) {
                let group = index < digits.count ? digits[index] : 0
                integer += index == 0 ? String(group) : String(format: "%04d", group)
            }
        }
        var fraction = ""
        if scale > 0 {
            var index = Int(weight) + 1
            if index < 0 { fraction += String(repeating: "0000", count: -index); index = 0 }
            while fraction.count < Int(scale) {
                let group = index < digits.count && index >= 0 ? digits[index] : 0
                fraction += String(format: "%04d", group)
                index += 1
            }
            fraction = String(fraction.prefix(Int(scale)))
        }
        let body = scale > 0 ? integer + "." + fraction : integer
        return sign == 0x4000 ? "-" + body : body
    }

    private static func money(_ cents: Int64) -> String {
        let negative = cents < 0
        let magnitude = cents.magnitude
        return (negative ? "-" : "") + "\(magnitude / 100).\(String(format: "%02d", Int(magnitude % 100)))"
    }

    // MARK: Datas e horas (época do PostgreSQL: 2000-01-01)

    private static func civil(daysSince2000 days: Int64) -> (year: Int64, month: Int64, day: Int64) {
        // Algoritmo "civil_from_days" (H. Hinnant), deslocado de 1970 para 2000 (10.957 dias).
        let z = days + 10_957 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let day = doy - (153 * mp + 2) / 5 + 1
        let month = mp < 10 ? mp + 3 : mp - 9
        return (yoe + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    private static func dateString(_ days: Int64) -> String {
        let (year, month, day) = civil(daysSince2000: days)
        let era = year <= 0 ? " BC" : ""
        let shown = year <= 0 ? 1 - year : year
        return String(format: "%04lld-%02lld-%02lld", shown, month, day) + era
    }

    static func date(_ days: Int32) -> String {
        if days == .max { return "infinity" }
        if days == .min { return "-infinity" }
        return dateString(Int64(days))
    }

    static func time(_ micros: Int64) -> String {
        let seconds = micros / 1_000_000
        let fraction = micros % 1_000_000
        let base = String(format: "%02lld:%02lld:%02lld", seconds / 3_600, seconds / 60 % 60, seconds % 60)
        return fraction == 0 ? base : base + "." + trimmedMicros(fraction)
    }

    static func timestamp(_ micros: Int64) -> String {
        if micros == .max { return "infinity" }
        if micros == .min { return "-infinity" }
        let microsPerDay: Int64 = 86_400_000_000
        var days = micros / microsPerDay
        var remainder = micros % microsPerDay
        if remainder < 0 { remainder += microsPerDay; days -= 1 }
        let date = dateString(days)
        // Era "BC" fica no fim, como o PostgreSQL mostra.
        if date.hasSuffix(" BC") { return String(date.dropLast(3)) + " " + time(remainder) + " BC" }
        return date + " " + time(remainder)
    }

    private static func trimmedMicros(_ fraction: Int64) -> String {
        var text = String(format: "%06lld", fraction)
        while text.hasSuffix("0") { text.removeLast() }
        return text
    }

    private static func offset(_ seconds: Int) -> String {
        let sign = seconds < 0 ? "-" : "+"
        let magnitude = abs(seconds)
        let hours = magnitude / 3_600, minutes = magnitude / 60 % 60, secs = magnitude % 60
        var text = sign + String(format: "%02d", hours)
        if minutes != 0 || secs != 0 { text += String(format: ":%02d", minutes) }
        if secs != 0 { text += String(format: ":%02d", secs) }
        return text
    }

    /// Formato próximo do `IntervalStyle = postgres`: "1 year 2 mons 3 days 04:05:06".
    static func interval(micros: Int64, days: Int32, months: Int32) -> String {
        var parts: [String] = []
        let years = months / 12, mons = months % 12
        if years != 0 { parts.append("\(years) year\(abs(years) == 1 ? "" : "s")") }
        if mons != 0 { parts.append("\(mons) mon\(abs(mons) == 1 ? "" : "s")") }
        if days != 0 { parts.append("\(days) day\(abs(days) == 1 ? "" : "s")") }
        if micros != 0 || parts.isEmpty {
            parts.append((micros < 0 ? "-" : "") + time(abs(micros)))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Rede

    private static func inet(_ b: inout ByteBuffer, cidr: Bool) -> String? {
        guard let family = b.readInteger(as: UInt8.self), let bits = b.readInteger(as: UInt8.self),
              b.readInteger(as: UInt8.self) != nil, let length = b.readInteger(as: UInt8.self),
              let raw = b.readBytes(length: Int(length)) else { return nil }
        let address: String
        let full: Int
        if family == 2 {                                                         // PGSQL_AF_INET
            address = raw.map(String.init).joined(separator: ".")
            full = 32
        } else {
            var groups: [String] = []
            for i in stride(from: 0, to: raw.count, by: 2) { groups.append(String(UInt16(raw[i]) << 8 | UInt16(raw[i + 1]), radix: 16)) }
            address = compressIPv6(groups)
            full = 128
        }
        return cidr || Int(bits) != full ? "\(address)/\(bits)" : address
    }

    /// Comprime a maior sequência de grupos zero (RFC 5952).
    private static func compressIPv6(_ groups: [String]) -> String {
        var bestStart = -1, bestLength = 0, start = -1
        for (index, group) in groups.enumerated() {
            if group == "0" {
                if start < 0 { start = index }
                if index - start + 1 > bestLength { bestStart = start; bestLength = index - start + 1 }
            } else {
                start = -1
            }
        }
        guard bestLength >= 2 else { return groups.joined(separator: ":") }
        let head = groups[..<bestStart].joined(separator: ":")
        let tail = groups[(bestStart + bestLength)...].joined(separator: ":")
        return head + "::" + tail
    }
}
