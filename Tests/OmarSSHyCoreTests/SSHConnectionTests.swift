import Foundation
import Testing
@testable import OmarSSHyCore

struct SSHConnectionTests {
    private let connection = SSHConnection(
        profile: SSHProfile(host: "omarchy", user: "developer", port: "2222"),
        controlPath: "/tmp/omarsshy-test/ssh.sock"
    )

    @Test func testSSHProfileTrimsValuesAndAcceptsAliasesAndIPv6() throws {
        #expect(try SSHProfile(host: " dev-box  ").validated() == SSHProfile(host: "dev-box"))
        let ipv6 = try SSHProfile(host: " [fe80::1%en0] ", user: "developer ", port: "02222").validated()
        #expect(ipv6.host == "fe80::1%en0")
        #expect(ipv6.destinationLabel == "developer@[fe80::1%en0]:2222")
    }

    @Test func testSSHProfileRejectsOptionsAndMalformedInputs() {
        for host in ["", "-Jhost", "someone@host", "host with spaces", "junk::host", "host;ls"] {
            #expect(throws: OmarSSHyError.invalidHost) {
                try SSHProfile(host: host).validated()
            }
        }
        #expect(throws: OmarSSHyError.invalidUser) {
            try SSHProfile(host: "box", user: "-root").validated()
        }
        for port in ["0", "65536", "1 2", "-4", "+22"] {
            #expect(throws: OmarSSHyError.invalidPort) {
                try SSHProfile(host: "box", port: port).validated()
            }
        }
    }

    @Test func testSSHArgumentsVerifyHostAndUseOnlyAppSocketForChildSessions() {
        #expect(connection.masterArguments.contains("StrictHostKeyChecking=ask"))
        #expect(connection.masterArguments.contains("ControlMaster=yes"))
        #expect(connection.masterArguments.contains("ForwardAgent=no"))
        #expect(!connection.masterArguments.contains("ProxyCommand=false"))
        #expect(Array(connection.masterArguments.suffix(3)) == ["-NT", "--", "omarchy"])
        #expect(connection.checkArguments.contains("check"))
        #expect(connection.exitArguments.contains("exit"))
        let list = connection.listArguments
        #expect(list.contains("ProxyCommand=false"))
        #expect(list.contains("BatchMode=yes"))
        #expect(list.contains("ControlMaster=no"))
        #expect(list.contains("/tmp/omarsshy-test/ssh.sock"))
    }

    @Test func testDiscoveryListsDirectDirectoriesAndDetectsOnlyArtisanFiles() throws {
        try withHome { home in
            let work = home.appendingPathComponent("work")
            let present = [
                "app 2", "app 10", ".oculto", "equipe d'Água", "projeto\ncom quebra", "artisan-pasta"
            ]
            for name in present {
                try FileManager.default.createDirectory(
                    at: work.appendingPathComponent(name), withIntermediateDirectories: true
                )
            }
            try Data().write(to: work.appendingPathComponent("app 2/artisan"))
            try Data().write(to: work.appendingPathComponent("README.md"))
            try FileManager.default.createDirectory(
                at: work.appendingPathComponent("artisan-pasta/artisan/subprojeto"), withIntermediateDirectories: true
            )
            let result = try run(try #require(connection.listArguments.last), home: home)
            #expect(result.status == 0)
            let workspace = try SSHConnection.parseWorkspace(Data("welcome\n".utf8) + result.output)
            #expect(workspace.directory == .work)
            let projects = workspace.projects
            #expect(Set(projects.map(\.name)) == Set(present))
            #expect(projects.filter(\.isLaravel).map(\.name) == ["app 2"])
            let appNames = projects.map(\.name).filter { $0.hasPrefix("app") }
            #expect(appNames == ["app 2", "app 10"])
        }
    }

    @Test func testMissingWorkIsEmptyAndAFileAtWorkIsAnError() throws {
        try withHome { home in
            let command = try #require(connection.listArguments.last)
            let empty = try run(command, home: home)
            #expect(empty.status == 0)
            #expect(try SSHConnection.parseWorkspace(empty.output) == RemoteWorkspace(directory: .work, projects: []))

            try Data().write(to: home.appendingPathComponent("work"))
            let inaccessible = try run(command, home: home)
            #expect(inaccessible.status != 0)
            #expect(throws: OmarSSHyError.invalidProjectList) { try SSHConnection.parseWorkspace(inaccessible.output) }
        }
    }

    @Test func testIncompleteProjectProtocolFailsInsteadOfReturningPartialResults() {
        #expect(throws: OmarSSHyError.invalidProjectList) { try SSHConnection.parseWorkspace(Data("banner only\n".utf8)) }
        #expect(throws: OmarSSHyError.invalidProjectList) {
            try SSHConnection.parseWorkspace(Data("\0OMARSSHY_PROJECTS_V2\0Work\0folder\0apple\0".utf8))
        }
        #expect(throws: OmarSSHyError.invalidProjectList) {
            try SSHConnection.parseWorkspace(Data("\0OMARSSHY_PROJECTS_V2\0anotherDirectory\0done\0".utf8))
        }
    }

    @Test func testUppercaseWorkFindsNestedRootsAndSkipsDependenciesAndSymlinks() throws {
        try withHome { home in
            let work = home.appendingPathComponent("Work")
            for path in [
                "teams/one/service/.git", "teams/two/service", "ordinary/docs",
                "worktree/subfolder", "ordinary/vendor/dependency", "links"
            ] {
                try FileManager.default.createDirectory(
                    at: work.appendingPathComponent(path), withIntermediateDirectories: true
                )
            }
            for path in ["teams/two/service/artisan", "worktree/.git", "worktree/subfolder/artisan",
                         "ordinary/vendor/dependency/artisan"] {
                try Data().write(to: work.appendingPathComponent(path))
            }
            let outside = home.appendingPathComponent("external")
            try FileManager.default.createDirectory(
                at: outside.appendingPathComponent("unlisted/.git"), withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: work.appendingPathComponent("links/external"), withDestinationURL: outside
            )

            let result = try run(try #require(connection.listArguments.last), home: home)
            #expect(result.status == 0)
            let workspace = try SSHConnection.parseWorkspace(result.output)
            #expect(workspace.directory == .capitalizedWork)
            #expect(Set(workspace.projects.map(\.relativePath)) == Set([
                "links", "ordinary", "teams/one/service", "teams/two/service", "worktree"
            ]))
            let sameName = workspace.projects.filter { $0.name == "service" }
            #expect(Set(sameName.map(\.id)).count == 2)
            #expect(sameName.filter(\.isLaravel).map(\.displayPath) == ["~/Work/teams/two/service"])
        }
    }

    @Test func testUppercaseWorkspaceExecutesCommandsAndCreatesRepositoriesInResolvedDirectory() throws {
        try withHome { home in
            let path = "groupe d'Água/projeto"
            let project = RemoteProject(name: "projeto", isLaravel: true, directory: .capitalizedWork, relativePath: path)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Work/" + path), withIntermediateDirectories: true
            )
            let binaries = try installExecutable(
                "shell", body: #"printf '%s\n%s\n' "${PWD#"$HOME"/}" "$*""#, home: home
            )
            _ = try installExecutable("php", body: #"printf '%s\n%s\n' "${PWD#"$HOME"/}" "$*""#, home: home)
            _ = try installExecutable("git", body: #"printf '%s\n' "$3""#, home: home)

            let shell = try run(
                try #require(connection.shellArguments(for: project).last),
                home: home, binaries: binaries, shell: binaries.appendingPathComponent("shell").path
            )
            #expect(shell.status == 0)
            #expect(String(decoding: shell.output, as: UTF8.self) == "Work/\(path)\n-i\n")

            let artisan = try run(try #require(connection.artisanArguments(.routes, project: project).last),
                                   home: home, binaries: binaries, shell: "/bin/bash")
            #expect(artisan.status == 0)
            #expect(String(decoding: artisan.output, as: UTF8.self) == "Work/\(path)\nartisan route:list\n")

            for (folder, directory) in [
                ("automatic", nil), ("explicit", ProjectDirectory.capitalizedWork)
            ] {
                let operation = RepositoryOperation.initialize(name: folder)
                let arguments = try connection.repositoryArguments(operation, in: directory)
                let result = try run(try #require(arguments.last), home: home, binaries: binaries)
                #expect(result.status == 0)
                #expect(String(decoding: result.output, as: UTF8.self) == home.path + "/Work/\(folder)\n")
            }
            let folders = try FileManager.default.contentsOfDirectory(atPath: home.path)
            #expect(!folders.contains("work"))
        }
    }

    @Test func testProjectShellRejectsAncestorAndAbsolutePaths() throws {
        try withHome { home in
            for path in ["../external", "nested/../outside", "nested//inside", "/nested", "nested/", ""] {
                let project = RemoteProject(name: "unsafe", isLaravel: false, relativePath: path)
                let result = try run(try #require(connection.shellArguments(for: project).last), home: home)
                #expect(result.status == 2)
            }
        }
    }

    @Test func testArtisanExecutesInSelectedProjectAndPreservesExitStatus() throws {
        try withHome { home in
            let name = "d'Água $(touch forbidden)"
            let project = home.appendingPathComponent("work").appendingPathComponent(name)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            let binaries = try installExecutable("php", body: #"""
                printf '%s\n%s\n' "${PWD##*/}" "$*"
                exit 7
                """#, home: home)
            let remote = RemoteProject(name: name, isLaravel: true)
            let arguments = connection.artisanArguments(.routes, project: remote)
            #expect(arguments.contains("-tt"))
            let result = try run(try #require(arguments.last), home: home, binaries: binaries, shell: "/bin/bash")
            #expect(result.status == 7)
            #expect(String(decoding: result.output, as: UTF8.self) == "\(name)\nartisan route:list\n")
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("forbidden").path))
            #expect(ArtisanCommand.migrate.requiresConfirmation)
            #expect(ArtisanCommand.clearCache.requiresConfirmation)
            #expect(!ArtisanCommand.routes.requiresConfirmation)
        }
    }

    @Test func testArtisanLoadsInteractiveShellPathAndRestoresProjectDirectory() throws {
        try withHome { home in
            let path = "grupo d'Água/site"
            let project = RemoteProject(name: "site", isLaravel: true, directory: .capitalizedWork, relativePath: path)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Work/" + path), withIntermediateDirectories: true
            )
            _ = try installExecutable("php", body: #"""
                printf '%s\n%s\n' "${PWD#"$HOME"/}" "$*"
                exit 23
                """#, home: home)
            let startup = #"""
                case $- in
                    *i*) export PATH="$HOME/bin:$PATH" ;;
                    *) return ;;
                esac
                cd "$HOME"
                """#
            try Data(startup.utf8).write(to: home.appendingPathComponent(".bashrc"))

            let command = try #require(connection.artisanArguments(.routes, project: project).last)
            let result = try run(command, home: home, shell: "/bin/bash")
            #expect(result.status == 23)
            #expect(String(decoding: result.output, as: UTF8.self) == "Work/\(path)\nartisan route:list\n")
        }
    }

    @Test func testShellOpensInProjectWithInteractiveFlag() throws {
        try withHome { home in
            let binaries = try installExecutable("shell", body: #"printf '%s\n%s\n' "${PWD##*/}" "$*""#, home: home)
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("work/a b"), withIntermediateDirectories: true
            )
            let project = RemoteProject(name: "a b", isLaravel: false)
            let arguments = connection.shellArguments(for: project)
            let result = try run(
                try #require(arguments.last), home: home, binaries: binaries,
                shell: binaries.appendingPathComponent("shell").path
            )
            #expect(result.status == 0)
            #expect(String(decoding: result.output, as: UTF8.self) == "a b\n-i\n")
        }
    }

    @Test func testGitInitCreatesRepoAndPreservesExistingFolder() throws {
        try withHome { home in
            let name = "Projeto d'Água"
            let operation = RepositoryOperation.initialize(name: name)
            let command = try #require(connection.repositoryArguments(operation).last)
            #expect(try run(command, home: home).status == 0)

            let folder = home.appendingPathComponent("work").appendingPathComponent(name)
            #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".git").path))
            let sentinel = folder.appendingPathComponent("existing")
            try Data("preservado".utf8).write(to: sentinel)

            #expect(try run(command, home: home).status != 0)
            #expect(try Data(contentsOf: sentinel) == Data("preservado".utf8))
        }
    }

    @Test func testClonePassesLiteralURLAndRemovesOnlyEmptyReservationOnFailure() throws {
        try withHome { home in
            let binaries = try installExecutable("git", body: #"""
                for arg do printf '%s\n' "$arg"; done
                exit 9
                """#, home: home)
            let operation = RepositoryOperation.clone(url: "git@github.com:org/a'bc.git", name: "clone")
            let arguments = try connection.repositoryArguments(operation)
            let result = try run(try #require(arguments.last), home: home, binaries: binaries)
            #expect(result.status == 9)
            #expect(String(decoding: result.output, as: UTF8.self).contains(
                "clone\n--progress\n--\ngit@github.com:org/a'bc.git\n"
            ))
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("work/clone").path))
        }
    }

    @Test func testRepositoryRejectsTraversalCredentialsAndUnsupportedTransports() throws {
        for name in [".", "..", "../exit", "/tmp", "a/b", "x\\win", "embedded\nline", "\0"] {
            #expect(throws: OmarSSHyError.invalidRepositoryName) {
                try connection.repositoryArguments(.initialize(name: name))
            }
        }
        for url in [
            "ext::sh", "file:///tmp/repo", "git://host/repo", "https://token@host/repo",
            "https://host/repo?token=secret", "ssh://git:secret@host/repo", "host:-x"
        ] {
            #expect(throws: OmarSSHyError.invalidRepositoryURL) {
                try connection.repositoryArguments(.clone(url: url, name: "test"))
            }
        }
        for url in ["https://git.example.com/team/repo.git", "ssh://git@git.example.com:2222/team/repo.git"] {
            _ = try connection.repositoryArguments(.clone(url: url, name: "repo"))
        }
    }

    @Test func testGitHubListsPaginatedOwnersAndPrivateRepositoriesThroughInteractiveShell() throws {
        try withHome { home in
            try installGitHubCLI(body: #"""
                [ "$GH_HOST" = github.com ] && [ "$GH_PROMPT_DISABLED" = 1 ] || exit 91
                case "$1:$2" in
                    api:user)
                        [ "$3" = --jq ] && [ "$4" = '{login} | @json' ] || exit 92
                        printf '%s\n' '{"login":"Pessoa"}' ;;
                    api:--paginate)
                        [ "$4" = --jq ] || exit 93
                        case "$3" in
                            'user/orgs?per_page=100')
                                [ "$5" = '.[] | {login} | @json' ] || exit 94
                                printf '%s\n' '{"login":"Zeta"}' '{"login":"acme"}' '{"login":"ACME"}' ;;
                            'user/repos?affiliation=owner&visibility=all&per_page=100')
                                [ "$5" = '.[] | {name, full_name, description, private} | @json' ] || exit 95
                                printf '%s\n' \
                                  '{"name":"last","full_name":"Pessoa/last","description":null,"private":false}' \
                                  '{"name":"first","full_name":"Pessoa/first","description":"linha 1\nlinha 2","private":true}' ;;
                            'orgs/acme/repos?type=all&per_page=100')
                                [ "$5" = '.[] | {name, full_name, description, private} | @json' ] || exit 96
                                printf '%s\n' '{"name":"app","full_name":"Acme/app","description":null,"private":true}' ;;
                            *) exit 97 ;;
                        esac ;;
                    *) exit 98 ;;
                esac
                """#, home: home)
            let profileArguments = try connection.gitHubArguments(.profile)
            #expect(profileArguments.contains("-T"))
            #expect(profileArguments.contains("ProxyCommand=false"))
            let profile = try run(try #require(profileArguments.last), home: home, shell: "/bin/bash")
            let organizations = try run(
                try #require(connection.gitHubArguments(.organizations).last), home: home, shell: "/bin/bash"
            )
            #expect(profile.status == 0 && organizations.status == 0)
            #expect(profile.output.starts(with: Data("Mensagem do shell\n".utf8)))
            let owners = try GitHubRequest.parseOwners(profile: profile.output, organizations: organizations.output)
            #expect(owners.map(\.login) == ["Pessoa", "acme", "Zeta"])
            #expect(owners.map(\.kind) == [.personal, .organization, .organization])

            let personal = try #require(owners.first)
            let personalResult = try run(
                try #require(connection.gitHubArguments(.repositories(personal)).last),
                home: home, shell: "/bin/bash"
            )
            #expect(personalResult.status == 0)
            let personalRepos = try GitHubRequest.parseRepositories(personalResult.output, for: personal)
            #expect(personalRepos.map(\.name) == ["first", "last"])
            #expect(personalRepos.first?.description == "linha 1\nlinha 2")
            #expect(personalRepos.filter(\.isPrivate).map(\.fullName) == ["Pessoa/first"])

            let organization = try #require(owners.first { $0.login == "acme" })
            let orgResult = try run(
                try #require(connection.gitHubArguments(.repositories(organization)).last),
                home: home, shell: "/bin/bash"
            )
            #expect(orgResult.status == 0)
            let orgRepos = try GitHubRequest.parseRepositories(orgResult.output, for: organization)
            #expect(orgRepos == [GitHubRepository(name: "app", fullName: "Acme/app", isPrivate: true)])
        }
    }

    @Test func testGitHubRejectsUnexpectedScopesAndReturnsSanitizedErrors() throws {
        let owner = GitHubOwner(login: "previous-account", kind: .personal)
        let output = GitHubRequest.marker + Data(
            #"{"name":"app","full_name":"new-account/app","description":null,"private":true}"#.utf8
        )
        #expect(throws: OmarSSHyError.invalidGitHubResponse) {
            try GitHubRequest.parseRepositories(output, for: owner)
        }
        #expect(throws: OmarSSHyError.invalidGitHubResponse) {
            try GitHubRequest.parseRepositories(Data("startup banner".utf8), for: owner)
        }
        for (status, diagnostic, error) in [
            (127, "gh not found", OmarSSHyError.gitHubCLIUnavailable),
            (4, "gh auth login", .gitHubAuthenticationRequired),
            (1, "HTTP 401: Bad credentials", .gitHubAuthenticationRequired),
            (1, "HTTP 403: Resource not accessible", .gitHubAccessDenied),
            (1, "dial tcp api.github.com: i/o timeout", .gitHubNetworkUnavailable),
            (1, "working directory details", .gitHubRequestFailed),
            (255, "connection closed", .connectionUnavailable)
        ] {
            #expect(throws: error) {
                try GitHubRequest.check(status: Int32(status), errors: Data(diagnostic.utf8))
            }
        }
    }

    @Test func testGitHubCloneUsesRemoteCLIAndReservedDestination() throws {
        try withHome { home in
            try FileManager.default.createDirectory(
                at: home.appendingPathComponent("Work"), withIntermediateDirectories: false
            )
            try installGitHubCLI(body: #"""
                [ "$GH_HOST" = github.com ] && [ "$GIT_TERMINAL_PROMPT" = 0 ] || exit 91
                [ "$1" = repo ] && [ "$2" = clone ] && [ -d "$4" ] || exit 92
                [ "$5" = --no-upstream ] && [ "$6" = -- ] && [ "$7" = --progress ] || exit 93
                printf '%s\n' "$3" "$4"
                [ "$3" != acme/failure ] || exit 9
                : > "$4/.git"
                """#, home: home)
            let repository = GitHubRepository(name: "app", fullName: "acme/app", isPrivate: true)
            let name = "projeto d'Água"
            let args = try connection.repositoryArguments(
                .cloneGitHub(repository: repository, name: name), in: .capitalizedWork
            )
            #expect(args.contains("-tt"))
            let command = try #require(args.last)
            let clone = try run(command, home: home, shell: "/bin/bash")
            #expect(clone.status == 0)
            let dest = home.appendingPathComponent("Work/" + name)
            #expect(String(decoding: clone.output, as: UTF8.self).hasSuffix("acme/app\n\(dest.path)\n"))
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))
            let duplicate = try run(command, home: home, shell: "/bin/bash")
            #expect(duplicate.status != 0)
            #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".git").path))

            let failingRepo = GitHubRepository(name: "failure", fullName: "acme/failure", isPrivate: false)
            let failing = try connection.repositoryArguments(.cloneGitHub(repository: failingRepo, name: "empty"))
            let failure = try run(try #require(failing.last), home: home, shell: "/bin/bash")
            #expect(failure.status == 9)
            #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("Work/empty").path))
        }
    }

    @Test func testGitHubRejectsUnsafeOwnerAndRepositoryArguments() {
        for login in ["", "--help", "../acme", "acme/workgroup", "owner?limit=100", "example.com"] {
            #expect(throws: OmarSSHyError.invalidGitHubOwner) {
                try connection.gitHubArguments(.repositories(GitHubOwner(login: login, kind: .organization)))
            }
        }
        for fullName in ["", "--help", "acme/..", "acme/other/nested", "acme/repo;ls", "acme/file:repo"] {
            let repo = GitHubRepository(name: "app", fullName: fullName, isPrivate: true)
            #expect(throws: OmarSSHyError.invalidGitHubRepository) {
                try connection.repositoryArguments(.cloneGitHub(repository: repo, name: "repo"))
            }
        }
    }

    private func installGitHubCLI(body: String, home: URL) throws {
        _ = try installExecutable("gh", body: body, home: home)
        let startup = #"""
            printf '%s\n' 'Mensagem do shell'
            export PATH="$HOME/bin:$PATH"
            """#
        try Data(startup.utf8).write(to: home.appendingPathComponent(".bashrc"))
    }

    private func withHome(_ body: (URL) throws -> Void) throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(
            "omarsshy-test-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try body(temporary)
    }

    private func installExecutable(_ name: String, body: String, home: URL) throws -> URL {
        let bin = home.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let executable = bin.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return bin
    }

    private func run(
        _ command: String, home: URL, binaries: URL? = nil, shell: String = "/bin/sh"
    ) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = home
        process.environment = [
            "HOME": home.path,
            "PATH": (binaries.map { "\($0.path):" } ?? "") + "/usr/bin:/bin",
            "GIT_CONFIG_NOSYSTEM": "1",
            "SHELL": shell
        ]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }
}
