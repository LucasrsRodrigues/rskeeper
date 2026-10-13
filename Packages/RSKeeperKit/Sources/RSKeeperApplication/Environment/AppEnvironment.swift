import Foundation
import RSKeeperSecurity

/// Resolução do ambiente e da raiz de dados, **antes** de qualquer acesso a dados ou logs (W0-T12).
///
/// Build Test (fail-closed, NT-SEC-14): exige `-RSKeeperDataRoot <dir|nome>`; o diretório (resolvido, sem
/// symlinks) precisa estar dentro do temporário do sistema e não pode ser nem conter as raízes de
/// Dev ou Produção. Builds Dev e Release **ignoram** o argumento (NT-SEC-22).
public struct AppEnvironment: Sendable, Equatable {
    public static let dataRootArgument = "-RSKeeperDataRoot"

    public let kind: AppEnvironmentKind
    public let dataRoot: DataRoot
    /// Indica se o argumento de raiz foi recebido mas ignorado (Dev/Release).
    public let ignoredDataRootArgument: Bool

    public enum GuardError: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownEnvironment(String)
        case missingDataRoot
        case dataRootOutsideTemporaryDirectory(String)
        case dataRootOverlapsProtectedRoot(String)

        public var description: String {
            switch self {
            case .unknownEnvironment(let value):
                "Ambiente desconhecido no Info.plist (RSKEnvironment = \(value))."
            case .missingDataRoot:
                "Build Test exige \(AppEnvironment.dataRootArgument) <diretório temporário>."
            case .dataRootOutsideTemporaryDirectory(let path):
                "A raiz de teste precisa estar no diretório temporário do sistema: \(path)"
            case .dataRootOverlapsProtectedRoot(let path):
                "A raiz de teste coincide com (ou contém) a raiz de Dev ou Produção: \(path)"
            }
        }
    }

    /// Resolve o ambiente.
    /// - Parameters:
    ///   - environmentName: valor de `RSKEnvironment` no Info.plist (`dev`, `test`, `prod`).
    ///   - arguments: argumentos do processo.
    ///   - temporaryDirectory: diretório temporário do sistema.
    ///   - applicationSupport: `Application Support` do processo (container no sandbox).
    ///   - protectedRoots: raízes que um teste nunca pode usar (Dev e Produção, com e sem container).
    public static func resolve(environmentName: String, arguments: [String], temporaryDirectory: URL,
                               applicationSupport: URL, protectedRoots: [URL]) throws(GuardError) -> AppEnvironment {
        guard let kind = AppEnvironmentKind(rawValue: environmentName) else { throw .unknownEnvironment(environmentName) }
        let requested = value(after: dataRootArgument, in: arguments)

        guard kind == .test else {
            return AppEnvironment(kind: kind, dataRoot: .standard(for: kind, applicationSupport: applicationSupport),
                                  ignoredDataRootArgument: requested != nil)
        }
        guard let requested, !requested.isEmpty else { throw .missingDataRoot }
        // Valor relativo = nome de subdiretório do temporário do PRÓPRIO processo (no sandbox, o tmp
        // do container, único lugar gravável sem grant). Sem barras nem "..".
        let requestedURL: URL
        if requested.hasPrefix("/") {
            requestedURL = URL(fileURLWithPath: requested, isDirectory: true)
        } else {
            guard !requested.contains("/"), requested != ".", requested != ".." else {
                throw .dataRootOutsideTemporaryDirectory(requested)
            }
            requestedURL = temporaryDirectory.appendingPathComponent(requested, isDirectory: true)
        }
        let candidate = canonical(requestedURL)
        let temporary = canonical(temporaryDirectory)
        guard isInside(candidate, temporary), candidate != temporary else {
            throw .dataRootOutsideTemporaryDirectory(candidate.path)
        }
        for protected in protectedRoots.map(canonical) where isInside(candidate, protected) || isInside(protected, candidate) {
            throw .dataRootOverlapsProtectedRoot(candidate.path)
        }
        return AppEnvironment(kind: .test, dataRoot: DataRoot(url: candidate), ignoredDataRootArgument: false)
    }

    /// Raízes protegidas padrão: Dev e Produção, com e sem container.
    public static func defaultProtectedRoots(home: URL, bundleIDBase: String) -> [URL] {
        var roots: [URL] = []
        for kind in [AppEnvironmentKind.dev, .prod] {
            let plain = home.appendingPathComponent("Library/Application Support/\(kind.folderName)", isDirectory: true)
            let container = home.appendingPathComponent(
                "Library/Containers/\(bundleIDBase)\(kind.bundleIDSuffix)/Data/Library/Application Support/\(kind.folderName)",
                isDirectory: true)
            roots += [plain, container]
        }
        return roots
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    /// Caminho absoluto e padronizado com **todos** os symlinks resolvidos, inclusive links pendentes
    /// (cujo destino ainda não existe) — `resolvingSymlinksInPath` não resolve esses, e um link pendente
    /// para a raiz de produção poderia ser criado agora e ativado depois.
    static func canonical(_ url: URL) -> URL {
        let fileManager = FileManager.default
        // Sem `standardizedFileURL` aqui: ele remove o prefixo `/private` e desfaria a resolução.
        var pending = url.path.split(separator: "/").map(String.init)
        var resolved = "/"
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                resolved = (resolved as NSString).deletingLastPathComponent
                continue
            }
            let candidate = (resolved as NSString).appendingPathComponent(component)
            if let type = try? fileManager.attributesOfItem(atPath: candidate)[.type] as? FileAttributeType,
               type == .typeSymbolicLink,
               let destination = try? fileManager.destinationOfSymbolicLink(atPath: candidate) {
                hops += 1
                guard hops <= 40 else { return URL(fileURLWithPath: candidate, isDirectory: true) }
                let target = destination.hasPrefix("/") ? destination : (resolved as NSString).appendingPathComponent(destination)
                pending = target.split(separator: "/").map(String.init) + pending
                resolved = "/"
                continue
            }
            resolved = candidate
        }
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    static func isInside(_ candidate: URL, _ root: URL) -> Bool {
        let path = candidate.path
        let rootPath = root.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
