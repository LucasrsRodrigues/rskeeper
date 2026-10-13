import Foundation

/// Identificador tipado sobre `UUID` (docs/native/03 §1, princípio 2).
///
/// O parâmetro fantasma `Kind` impede trocar um `ProfileID` por um `TabID` por engano.
public struct TypedID<Kind>: Hashable, Sendable, Codable, CustomStringConvertible {
    public let raw: UUID

    public init(raw: UUID) { self.raw = raw }

    /// Gera um identificador novo, ordenável por criação (UUIDv7).
    public static func generate() -> TypedID<Kind> { TypedID(raw: UUIDv7.generate()) }

    public var description: String { raw.uuidString }

    // `Kind` é só um marcador de compilação; não participa de igualdade nem de serialização.
    public static func == (lhs: TypedID<Kind>, rhs: TypedID<Kind>) -> Bool { lhs.raw == rhs.raw }
    public func hash(into hasher: inout Hasher) { hasher.combine(raw) }
    public init(from decoder: Decoder) throws { raw = try decoder.singleValueContainer().decode(UUID.self) }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// Marcadores de tipo dos identificadores.
public enum IDKind {
    public enum Profile {}
    public enum Folder {}
    public enum Session {}
    public enum Window {}
    public enum Tab {}
    public enum Execution {}
    public enum Result {}
    public enum Job {}
    public enum SavedQuery {}
    public enum Draft {}
    public enum Environment {}
}

public typealias ProfileID = TypedID<IDKind.Profile>
public typealias FolderID = TypedID<IDKind.Folder>
public typealias SessionID = TypedID<IDKind.Session>
public typealias WindowID = TypedID<IDKind.Window>
public typealias TabID = TypedID<IDKind.Tab>
public typealias ExecutionID = TypedID<IDKind.Execution>
public typealias ResultID = TypedID<IDKind.Result>
public typealias JobID = TypedID<IDKind.Job>
public typealias SavedQueryID = TypedID<IDKind.SavedQuery>
public typealias DraftID = TypedID<IDKind.Draft>
public typealias EnvironmentID = TypedID<IDKind.Environment>

/// Gerador de UUID versão 7 (RFC 9562): 48 bits de milissegundos Unix + bits aleatórios.
public enum UUIDv7 {
    /// Gera um UUIDv7 a partir do instante e de uma fonte de bytes aleatórios (injetáveis em teste).
    public static func generate(
        now: Date = Date(),
        randomBytes: () -> [UInt8] = { (0..<10).map { _ in UInt8.random(in: .min ... .max) } }
    ) -> UUID {
        let millis = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        let random = randomBytes()
        precondition(random.count >= 10, "UUIDv7 precisa de 10 bytes aleatórios")
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<6 {
            bytes[index] = UInt8(truncatingIfNeeded: millis >> (8 * (5 - index)))
        }
        bytes[6] = 0x70 | (random[0] & 0x0F)        // versão 7
        bytes[7] = random[1]
        bytes[8] = 0x80 | (random[2] & 0x3F)        // variante RFC 4122/9562
        for index in 9..<16 { bytes[index] = random[index - 6] }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Versão do UUID (nibble alto do byte 6).
    public static func version(of uuid: UUID) -> Int { Int(uuid.uuid.6 >> 4) }

    /// Milissegundos Unix embutidos num UUIDv7.
    public static func timestampMillis(of uuid: UUID) -> UInt64 {
        let u = uuid.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5].reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
