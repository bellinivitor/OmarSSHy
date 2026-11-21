import Foundation

public struct GitHubOwner: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case personal
        case organization
    }

    public let login: String
    public let kind: Kind
    public var id: String { login.lowercased() }

    public init(login: String, kind: Kind) {
        self.login = login
        self.kind = kind
    }
}

public struct GitHubRepository: Identifiable, Hashable, Sendable, Decodable {
    public let name: String
    public let fullName: String
    public let description: String?
    public let isPrivate: Bool
    public var id: String { fullName.lowercased() }

    public init(name: String, fullName: String, description: String? = nil, isPrivate: Bool) {
        self.name = name
        self.fullName = fullName
        self.description = description
        self.isPrivate = isPrivate
    }

    private enum CodingKeys: String, CodingKey {
        case name, description
        case fullName = "full_name"
        case isPrivate = "private"
    }
}

enum GitHubRequest: Sendable {
    case profile
    case organizations
    case repositories(GitHubOwner)

    static let marker = Data("\0OMARSSHY_GITHUB_V1\0".utf8)

    // Disable credential prompts and debug output for this command only.
    static let command = "exec env GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_DEBUG= DEBUG= "
        + "GH_FORCE_TTY= NO_COLOR=1 GH_NO_UPDATE_NOTIFIER=1 GH_NO_EXTENSION_UPDATE_NOTIFIER=1 "
        + "GIT_TERMINAL_PROMPT=0 GIT_TRACE=0 GIT_TRACE_CURL=0 GIT_CURL_VERBOSE=0 gh"

    var arguments: [String] {
        switch self {
        case .profile:
            return ["api", "user", "--jq", "{login} | @json"]
        case .organizations:
            return ["api", "--paginate", "user/orgs?per_page=100", "--jq", ".[] | {login} | @json"]
        case .repositories(let owner):
            let endpoint: String
            switch owner.kind {
            case .personal:
                endpoint = "user/repos?affiliation=owner&visibility=all&per_page=100"
            case .organization:
                endpoint = "orgs/\(owner.login)/repos?type=all&per_page=100"
            }
            return ["api", "--paginate", endpoint, "--jq", ".[] | {name, full_name, description, private} | @json"]
        }
    }

    private struct Login: Decodable {
        let login: String
    }

    static func parseOwners(profile: Data, organizations: Data) throws -> [GitHubOwner] {
        let accounts = try decodeLines(Login.self, from: profile)
        guard accounts.count == 1, let account = accounts.first, isValidLogin(account.login) else {
            throw OmarSSHyError.invalidGitHubResponse
        }
        let personal = GitHubOwner(login: account.login, kind: .personal)
        let memberships = try decodeLines(Login.self, from: organizations)
        var seen: Set<String> = [personal.id]
        let orgs = try memberships.compactMap { member -> GitHubOwner? in
            guard isValidLogin(member.login) else { throw OmarSSHyError.invalidGitHubResponse }
            let organization = GitHubOwner(login: member.login, kind: .organization)
            return seen.insert(organization.id).inserted ? organization : nil
        }
        return [personal] + orgs.sorted {
            $0.login.localizedStandardCompare($1.login) == .orderedAscending
        }
    }

    static func parseRepositories(_ output: Data, for owner: GitHubOwner) throws -> [GitHubRepository] {
        let entries = try decodeLines(GitHubRepository.self, from: output)
        var seen = Set<String>()
        let repositories = try entries.filter { entry in
            let parts = entry.fullName.split(separator: "/")
            guard isValidFullName(entry.fullName),
                  parts.first?.lowercased() == owner.id, parts.last.map(String.init) == entry.name else {
                throw OmarSSHyError.invalidGitHubResponse
            }
            return seen.insert(entry.id).inserted
        }
        return repositories.sorted {
            $0.fullName.localizedStandardCompare($1.fullName) == .orderedAscending
        }
    }

    static func check(status: Int32, errors: Data) throws {
        switch status {
        case 0: return
        case 4: throw OmarSSHyError.gitHubAuthenticationRequired
        case 126, 127: throw OmarSSHyError.gitHubCLIUnavailable
        case 255: throw OmarSSHyError.connectionUnavailable
        default: break
        }

        // Keep remote diagnostics internal to this classification, since the
        // shell profile and CLI may print machine-specific information.
        let message = String(decoding: errors, as: UTF8.self).lowercased()
        if message.contains("http 401") || message.contains("gh auth login") || message.contains("bad credentials") {
            throw OmarSSHyError.gitHubAuthenticationRequired
        }
        if message.contains("http 403") && !message.contains("rate limit") {
            throw OmarSSHyError.gitHubAccessDenied
        }
        if message.contains("dial tcp") || message.contains("timeout")
            || message.contains("connection refused") || message.contains("network is unreachable") {
            throw OmarSSHyError.gitHubNetworkUnavailable
        }
        throw OmarSSHyError.gitHubRequestFailed
    }

    static func isValidLogin(_ login: String) -> Bool {
        let bytes = login.utf8
        guard bytes.count <= 100, let first = bytes.first, isASCIILetterOrDigit(first) else { return false }
        return bytes.allSatisfy { isASCIILetterOrDigit($0) || $0 == 45 || $0 == 95 }
    }

    static func isValidFullName(_ fullName: String) -> Bool {
        let segments = fullName.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count == 2, isValidLogin(String(segments[0])) else { return false }
        let repository = segments[1]
        guard !repository.isEmpty, repository != ".", repository != "..", repository.utf8.count <= 100 else {
            return false
        }
        return repository.utf8.allSatisfy { isASCIILetterOrDigit($0) || $0 == 45 || $0 == 46 || $0 == 95 }
    }

    private static func isASCIILetterOrDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func decodeLines<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> [Value] {
        guard let range = data.range(of: marker) else { throw OmarSSHyError.invalidGitHubResponse }
        let payload = data[range.upperBound...]
        let decoder = JSONDecoder()
        do {
            return try payload.split(separator: 10).map { try decoder.decode(type, from: Data($0)) }
        } catch {
            throw OmarSSHyError.invalidGitHubResponse
        }
    }
}
