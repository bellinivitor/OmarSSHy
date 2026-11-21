import Darwin
import Foundation

public struct SSHProfile: Codable, Equatable, Sendable {
    public var host: String
    public var user: String
    public var port: String

    public init(host: String = "", user: String = "", port: String = "") {
        self.host = host
        self.user = user
        self.port = port
    }

    public var destinationLabel: String {
        let address = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let login = user.isEmpty ? "" : "\(user)@"
        let service = port.isEmpty ? "" : ":\(port)"
        return login + address + service
    }

    public func validated() throws -> SSHProfile {
        var host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = user.trimmingCharacters(in: .whitespacesAndNewlines)
        var port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]"), host.contains(":") {
            host = String(host.dropFirst().dropLast())
        }
        guard Self.isHost(host) else {
            throw OmarSSHyError.invalidHost
        }
        if !user.isEmpty {
            guard !user.hasPrefix("-"),
                  user.utf8.allSatisfy({ Self.isAlphaNumeric($0) || [45, 46, 95].contains($0) })
            else {
                throw OmarSSHyError.invalidUser
            }
        }
        if !port.isEmpty {
            guard port.utf8.allSatisfy({ (48...57).contains($0) }),
                  let number = UInt16(port), number > 0 else {
                throw OmarSSHyError.invalidPort
            }
            port = String(number)
        }
        return SSHProfile(host: host, user: user, port: port)
    }

    private static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, !host.hasPrefix("-"), !host.utf8.contains(0) else { return false }
        if host.contains(":") {
            let parts = host.split(separator: "%", omittingEmptySubsequences: false)
            guard let address = parts.first, parts.count <= 2 else { return false }
            if parts.count == 2 {
                let zone = parts[1]
                guard !zone.isEmpty, zone.utf8.allSatisfy({ isAlphaNumeric($0) || [45, 46, 95].contains($0) })
                else { return false }
            }
            var parsed = in6_addr()
            return String(address).withCString { inet_pton(AF_INET6, $0, &parsed) == 1 }
        }
        return host.utf8.allSatisfy { isAlphaNumeric($0) || [45, 46, 95].contains($0) }
            && host.utf8.contains(where: isAlphaNumeric)
    }

    private static func isAlphaNumeric(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }
}

public enum ProjectDirectory: String, Hashable, Sendable {
    case work
    case capitalizedWork = "Work"

    public var displayPath: String { "~/" + rawValue }
}

public struct RemoteWorkspace: Equatable, Sendable {
    public let directory: ProjectDirectory
    public let projects: [RemoteProject]

    public init(directory: ProjectDirectory, projects: [RemoteProject]) {
        self.directory = directory
        self.projects = projects
    }
}

public struct RemoteProject: Identifiable, Hashable, Sendable {
    public let name: String
    public let isLaravel: Bool
    public let directory: ProjectDirectory
    public let relativePath: String
    public var id: String { displayPath }
    public var displayPath: String { directory.displayPath + "/" + relativePath }

    public init(
        name: String, isLaravel: Bool, directory: ProjectDirectory = .work, relativePath: String? = nil
    ) {
        self.name = name
        self.isLaravel = isLaravel
        self.directory = directory
        self.relativePath = relativePath ?? name
    }
}

public enum ArtisanCommand: String, CaseIterable, Identifiable, Sendable {
    case list
    case routes = "route:list"
    case migrationStatus = "migrate:status"
    case migrate
    case test
    case clearCache = "optimize:clear"

    public var id: String { rawValue }
    public var command: String { "php artisan \(rawValue)" }

    public var title: String {
        switch self {
        case .list: "Comandos"
        case .routes: "Rotas"
        case .migrationStatus: "Status das migrações"
        case .migrate: "Migrar"
        case .test: "Testes"
        case .clearCache: "Limpar cache"
        }
    }

    public var icon: String {
        switch self {
        case .list: "list.bullet"
        case .routes: "point.topleft.down.to.point.bottomright.curvepath"
        case .migrationStatus: "list.bullet.clipboard"
        case .migrate: "arrow.up.to.line"
        case .test: "checkmark.circle"
        case .clearCache: "eraser"
        }
    }

    public var requiresConfirmation: Bool { self == .migrate || self == .clearCache }
}

public enum RepositoryOperation: Equatable, Sendable {
    case clone(url: String, name: String)
    case cloneGitHub(repository: GitHubRepository, name: String)
    case initialize(name: String)
}

public enum OmarSSHyError: LocalizedError, Equatable, Sendable {
    case invalidHost
    case invalidUser
    case invalidPort
    case invalidRepositoryName
    case invalidRepositoryURL
    case connectionUnavailable
    case invalidProjectList
    case invalidGitHubOwner
    case invalidGitHubRepository
    case invalidGitHubResponse
    case gitHubCLIUnavailable
    case gitHubAuthenticationRequired
    case gitHubAccessDenied
    case gitHubNetworkUnavailable
    case gitHubRequestFailed
    case sshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidHost: "Informe um host ou alias SSH válido."
        case .invalidUser: "Informe um usuário SSH válido."
        case .invalidPort: "Use uma porta entre 1 e 65535."
        case .invalidRepositoryName: "Informe um nome de pasta válido, sem barras nem caracteres de controle."
        case .invalidRepositoryURL: "Informe uma URL Git SSH ou HTTPS, sem credenciais embutidas."
        case .connectionUnavailable: "A conexão SSH foi encerrada. Conecte novamente."
        case .invalidProjectList: "O Omarchy devolveu uma lista de projetos em um formato inválido."
        case .invalidGitHubOwner: "Selecione uma conta ou organização válida do GitHub."
        case .invalidGitHubRepository: "Selecione um repositório válido do GitHub."
        case .invalidGitHubResponse: "O GitHub devolveu dados em um formato inesperado. Atualize a lista."
        case .gitHubCLIUnavailable: "O GitHub CLI (gh) não está disponível no shell do Omarchy."
        case .gitHubAuthenticationRequired: "Entre no GitHub pelo GitHub CLI no Omarchy e tente novamente."
        case .gitHubAccessDenied: "A conta do GitHub no Omarchy não tem acesso a esta lista de repositórios."
        case .gitHubNetworkUnavailable: "O Omarchy não conseguiu alcançar o GitHub. Verifique a conexão e tente novamente."
        case .gitHubRequestFailed: "Não foi possível consultar o GitHub pelo Omarchy. Tente novamente."
        case .sshFailed(let message): message
        }
    }
}
