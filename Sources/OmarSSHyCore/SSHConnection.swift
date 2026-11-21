import Foundation

public struct SSHConnection: Sendable {
    public static let executable = "/usr/bin/ssh"

    public let profile: SSHProfile
    public let controlPath: String
    private let configFile: String?

    public init(profile: SSHProfile, controlPath: String, configFile: String? = nil) {
        self.profile = profile
        self.controlPath = controlPath
        self.configFile = configFile
    }

    public var masterArguments: [String] {
        commonArguments + [
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "BatchMode=no",
            "-o", "StdinNull=no",
            "-o", "StrictHostKeyChecking=ask",
            "-o", "ConnectTimeout=12",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-NT", "--", profile.host
        ]
    }

    public var checkArguments: [String] {
        multiplexArguments + ["-O", "check", "--", profile.host]
    }

    public var exitArguments: [String] {
        multiplexArguments + ["-O", "exit", "--", profile.host]
    }

    public func check() async -> Bool {
        let arguments = checkArguments
        return await Task.detached(priority: .userInitiated) {
            (try? Self.execute(arguments).status) == 0
        }.value
    }

    public func listProjects() async throws -> [RemoteProject] {
        try await listWorkspace().projects
    }

    public func listWorkspace() async throws -> RemoteWorkspace {
        let arguments = listArguments
        return try await Task.detached(priority: .userInitiated) {
            let result = try Self.execute(arguments)
            guard result.status == 0 else {
                if result.status == 255 {
                    throw OmarSSHyError.connectionUnavailable
                }
                let text = String(decoding: result.errors, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw OmarSSHyError.sshFailed(
                    text.isEmpty ? "Não foi possível listar os projetos no Omarchy." : text
                )
            }
            return try Self.parseWorkspace(result.output)
        }.value
    }

    public func shellArguments(for project: RemoteProject) -> [String] {
        interactiveArguments(Self.projectScript(project, command: #"exec "${SHELL:-/bin/sh}" -i"#))
    }

    public func artisanArguments(_ command: ArtisanCommand, project: RemoteProject) -> [String] {
        let invocation = #"cd "$OMARSSHY_ARTISAN_DIR" && "# + command.command
        let launch = #"""
        OMARSSHY_ARTISAN_DIR="$PWD"
        export OMARSSHY_ARTISAN_DIR
        exec "${SHELL:-/bin/sh}" -i -c \#(Self.shellQuote(invocation))
        """#
        return interactiveArguments(Self.projectScript(project, command: launch))
    }

    public func repositoryArguments(
        _ operation: RepositoryOperation, in directory: ProjectDirectory? = nil
    ) throws -> [String] {
        interactiveArguments(try Self.repositoryScript(operation, in: directory))
    }

    public func gitHubOwners() async throws -> [GitHubOwner] {
        try await Task.detached(priority: .userInitiated) {
            let profile = try self.executeGitHubRequest(.profile)
            let organizations = try self.executeGitHubRequest(.organizations)
            return try GitHubRequest.parseOwners(profile: profile, organizations: organizations)
        }.value
    }

    public func gitHubRepositories(for owner: GitHubOwner) async throws -> [GitHubRepository] {
        try await Task.detached(priority: .userInitiated) {
            let output = try self.executeGitHubRequest(.repositories(owner))
            return try GitHubRequest.parseRepositories(output, for: owner)
        }.value
    }

    private func executeGitHubRequest(_ request: GitHubRequest) throws -> Data {
        let arguments = try gitHubArguments(request)
        let result = try Self.execute(arguments)
        try GitHubRequest.check(status: result.status, errors: result.errors)
        return result.output
    }

    func gitHubArguments(_ request: GitHubRequest) throws -> [String] {
        if case .repositories(let owner) = request, !GitHubRequest.isValidLogin(owner.login) {
            throw OmarSSHyError.invalidGitHubOwner
        }
        let arguments = request.arguments.map(Self.shellQuote).joined(separator: " ")
        let launch = #"printf '\000OMARSSHY_GITHUB_V1\000'; "# + GitHubRequest.command + " " + arguments
        let script = "exec " + Self.interactiveShellCommand(launch)
        return multiplexArguments + ["-T", "--", profile.host, Self.remoteCommand(script)]
    }

    private var commonArguments: [String] {
        var arguments = configFile.map { ["-F", $0] } ?? []
        arguments += [
            "-o", "ClearAllForwardings=yes",
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ForkAfterAuthentication=no",
            "-o", "RemoteCommand=none",
            "-o", "PermitLocalCommand=no",
            "-S", controlPath
        ]
        if !profile.user.isEmpty {
            arguments += ["-l", profile.user]
        }
        if !profile.port.isEmpty {
            arguments += ["-p", profile.port]
        }
        return arguments
    }

    // The proxy fails locally if OpenSSH cannot reuse this app's authenticated socket.
    private var multiplexArguments: [String] {
        commonArguments + [
            "-o", "ControlMaster=no", "-o", "BatchMode=yes", "-o", "ProxyCommand=false"
        ]
    }

    var listArguments: [String] {
        multiplexArguments + ["-T", "--", profile.host, Self.remoteCommand(Self.listScript)]
    }

    private func interactiveArguments(_ script: String) -> [String] {
        multiplexArguments + [
            "-o", "StdinNull=no", "-tt", "--", profile.host, Self.remoteCommand(script)
        ]
    }

    private static func remoteCommand(_ script: String) -> String {
        // OpenSSH hands this string to the login shell. The encoded body is
        // opaque to that shell and is evaluated by /bin/sh without taking over stdin.
        let encoded = Data(script.utf8).base64EncodedString()
        return #"/bin/sh -c 'code=$(printf %s "$1" | base64 -d) || exit 2; eval "$code"' omarsshy "# + encoded
    }

    private static let resolveProjectDirectory = #"""
    root_name=work
    for candidate in "$HOME"/[wW]ork; do
        [ -d "$candidate" ] || continue
        case "${candidate##*/}" in
            work) root_name=work; break ;;
            Work) root_name=Work ;;
        esac
    done
    """#

    static let listScript = #"""
    \#(resolveProjectDirectory)
    root="$HOME/$root_name"
    if [ -e "$root" ] || [ -L "$root" ]; then
        if [ ! -d "$root" ] || [ ! -r "$root" ] || [ ! -x "$root" ]; then
            printf 'Não foi possível acessar ~/%s no Omarchy.\n' "$root_name" >&2
            exit 1
        fi
    fi

    ignore_directory() {
        case "$1" in
            .git|node_modules|vendor|.cache|.build|.venv|venv|__pycache__|dist|build|target|coverage|.next|.nuxt|.output|Pods)
                return 0 ;;
        esac
        return 1
    }
    scan_projects() (
        directory=$1
        relative_path=$2
        if [ -f "$directory/artisan" ]; then
            printf 'laravel\000%s\000' "$relative_path"
            exit 0
        elif [ -d "$directory/.git" ] || [ -f "$directory/.git" ]; then
            printf 'folder\000%s\000' "$relative_path"
            exit 0
        fi
        [ ! -L "$directory" ] || exit 1
        found=1
        for child in "$directory"/* "$directory"/.[!.]* "$directory"/..?*; do
            [ -d "$child" ] && [ ! -L "$child" ] || continue
            child_name=${child##*/}
            ignore_directory "$child_name" && continue
            if scan_projects "$child" "$relative_path/$child_name"; then
                found=0
            fi
        done
        exit "$found"
    )

    printf '\000OMARSSHY_PROJECTS_V2\000%s\000' "$root_name"
    for folder in "$root"/* "$root"/.[!.]* "$root"/..?*; do
        [ -d "$folder" ] || continue
        name=${folder##*/}
        ignore_directory "$name" && continue
        if ! scan_projects "$folder" "$name"; then
            printf 'folder\000%s\000' "$name"
        fi
    done
    printf 'done\000'
    """#

    static func parseWorkspace(_ output: Data) throws -> RemoteWorkspace {
        let header = Data("\0OMARSSHY_PROJECTS_V2\0".utf8)
        guard let headerRange = output.range(of: header) else {
            throw OmarSSHyError.invalidProjectList
        }
        let fields = output[headerRange.upperBound...].split(separator: 0, omittingEmptySubsequences: false)
        guard let first = fields.first, let directory = ProjectDirectory(rawValue: String(decoding: first, as: UTF8.self)) else {
            throw OmarSSHyError.invalidProjectList
        }
        var projects: [RemoteProject] = []
        var index = 1
        while fields.indices.contains(index + 1) {
            let kind = String(decoding: fields[index], as: UTF8.self)
            if kind == "done" {
                let sorted = projects.sorted {
                    $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
                }
                return RemoteWorkspace(directory: directory, projects: sorted)
            }
            guard kind == "folder" || kind == "laravel" else {
                throw OmarSSHyError.invalidProjectList
            }
            if let path = String(data: fields[index + 1], encoding: .utf8) {
                let components = path.split(separator: "/", omittingEmptySubsequences: false)
                if let name = components.last,
                   components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) {
                    projects.append(RemoteProject(
                        name: String(name), isLaravel: kind == "laravel", directory: directory, relativePath: path
                    ))
                }
            }
            index += 2
        }
        throw OmarSSHyError.invalidProjectList
    }

    static func projectScript(_ project: RemoteProject, command: String) -> String {
        #"""
        root="$HOME"/\#(shellQuote(project.directory.rawValue))
        relative_path=\#(shellQuote(project.relativePath))
        case "/$relative_path/" in *//*|*/./*|*/../*) exit 2 ;; esac
        if ! cd "$root/$relative_path"; then exit 1; fi
        \#(command)
        """#
    }

    static func repositoryScript(
        _ operation: RepositoryOperation, in directory: ProjectDirectory?
    ) throws -> String {
        let name: String
        let gitCommand: String
        switch operation {
        case .clone(let inputURL, let folder):
            name = folder
            let url = inputURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isGitURL(url) else { throw OmarSSHyError.invalidRepositoryURL }
            gitCommand = "git -c protocol.allow=never -c protocol.ssh.allow=always "
                + "-c protocol.https.allow=always clone --progress -- \(shellQuote(url)) \"$dest\""
        case .cloneGitHub(let repository, let folder):
            name = folder
            guard GitHubRequest.isValidFullName(repository.fullName) else { throw OmarSSHyError.invalidGitHubRepository }
            let launch = GitHubRequest.command + " repo clone " + shellQuote(repository.fullName)
                + #" "$OMARSSHY_GITHUB_DEST" --no-upstream -- --progress"#
            gitCommand = #"""
            OMARSSHY_GITHUB_DEST="$dest"
            export OMARSSHY_GITHUB_DEST
            \#(interactiveShellCommand(launch))
            """#
        case .initialize(let folder):
            name = folder
            gitCommand = #"git init -- "$dest""#
        }
        let folder = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !folder.isEmpty, folder != ".", folder != "..", !folder.contains("/"),
              !folder.contains("\\"), folder.utf8.count <= 255,
              !folder.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw OmarSSHyError.invalidRepositoryName }

        let selectDirectory = directory.map { "root_name=" + shellQuote($0.rawValue) } ?? resolveProjectDirectory
        return #"""
        \#(selectDirectory)
        root="$HOME/$root_name"
        dest="$root"/\#(shellQuote(folder))
        mkdir -p -- "$root" || exit 1
        if ! mkdir -- "$dest"; then
            printf 'Não foi possível criar a pasta. Confira se o nome já existe em ~/%s.\n' "$root_name" >&2
            exit 1
        fi
        trap 'rmdir -- "$dest" 2>/dev/null || :' EXIT
        \#(gitCommand) || exit $?
        trap - EXIT
        """#
    }

    private static func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func interactiveShellCommand(_ script: String) -> String {
        #""${SHELL:-/bin/sh}" -i -c "# + shellQuote(script)
    }

    private static func isGitURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains("\\"),
              !url.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains)
        else { return false }

        if url.contains("://") {
            guard let components = URLComponents(string: url), let scheme = components.scheme?.lowercased(),
                  let host = components.host, !host.isEmpty, !components.path.isEmpty,
                  components.path != "/", components.password == nil,
                  components.query == nil, components.fragment == nil else { return false }
            if scheme == "https" { return components.user == nil }
            return scheme == "ssh"
        }

        // SCP-style URLs have a host before the colon and no URI scheme helper.
        return url.range(
            of: #"^(?:[A-Za-z0-9_.][A-Za-z0-9_.-]*@)?(?:[A-Za-z0-9_.][A-Za-z0-9_.-]*|\[[0-9A-Fa-f:.]+\]):[^:-].*$"#,
            options: .regularExpression
        ) != nil
    }

    private static func execute(_ arguments: [String]) throws -> (status: Int32, output: Data, errors: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        try process.run()
        // Drain both streams concurrently so verbose OpenSSH diagnostics cannot
        // fill stderr and block the stdout reader.
        let errorData = DispatchWorkItemResult()
        DispatchQueue.global(qos: .userInitiated).async {
            errorData.resolve(errors.fileHandleForReading.readDataToEndOfFile())
        }
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, outputData, errorData.wait())
    }
}

private final class DispatchWorkItemResult: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private var value = Data()

    func resolve(_ value: Data) {
        self.value = value
        semaphore.signal()
    }

    func wait() -> Data {
        semaphore.wait()
        return value
    }
}
