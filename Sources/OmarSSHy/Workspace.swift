import Darwin
import Foundation
import SwiftUI
import OmarSSHyCore

@MainActor
final class Workspace: ObservableObject {
    enum Phase {
        case disconnected, connecting, connected, failed
    }

    @Published var profile: SSHProfile
    @Published private(set) var phase = Phase.disconnected
    @Published private(set) var authentication: TerminalSession?
    @Published private(set) var projectDirectory: ProjectDirectory?
    @Published private(set) var projects: [RemoteProject] = []
    @Published private(set) var selectedProject: RemoteProject?
    @Published var search = ""
    @Published private(set) var sessions: [TerminalSession] = []
    @Published private(set) var activeSessionID: UUID?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isRunningGit = false
    @Published var connectionError: String?
    @Published private(set) var discoveryError: String?
    @Published var gitError: String?

    private let defaults: UserDefaults
    private var connection: SSHConnection?
    private var controlDirectory: URL?
    private var connectionID = UUID()
    private var connectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var discoveryTask: Task<Void, Never>?
    private var attemptedSavedConnection = false
    private var gitAttempt: UUID?
    private var gitSessionID: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "sshProfile"),
           let saved = try? JSONDecoder().decode(SSHProfile.self, from: data) {
            profile = saved
        } else {
            profile = SSHProfile(host: "", user: "", port: "")
        }
    }

    var visibleProjects: [RemoteProject] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty ? projects : projects.filter { $0.relativePath.localizedStandardContains(query) }
    }

    var activeSession: TerminalSession? {
        sessions.first { $0.id == activeSessionID }
    }

    func connectSavedProfile() {
        guard !attemptedSavedConnection else { return }
        attemptedSavedConnection = true
        guard phase == .disconnected, (try? profile.validated()) != nil else { return }
        connect()
    }

    func connect() {
        do {
            let target = try profile.validated()
            disconnect()
            let directory = try Self.makeControlDirectory()
            controlDirectory = directory
            let path = directory.appendingPathComponent("ssh").path
            let transport = SSHConnection(profile: target, controlPath: path)
            let attempt = connectionID
            connection = transport
            profile = target
            phase = .connecting
            authentication = TerminalSession(title: "Conexão SSH", arguments: transport.masterArguments) { [weak self] _ in
                guard let self, self.connectionID == attempt else { return }
                self.connectionLost()
            }
            guard phase == .connecting else { return }
            connectTask = Task { [weak self] in
                while !Task.isCancelled {
                    if await transport.check() {
                        guard let self, self.connectionID == attempt, self.phase == .connecting else { return }
                        self.phase = .connected
                        if let data = try? JSONEncoder().encode(target) {
                            self.defaults.set(data, forKey: "sshProfile")
                        }
                        self.startProjectDiscovery()
                        return
                    }
                    try? await Task.sleep(for: .milliseconds(240))
                }
            }
        } catch {
            connectionError = error.localizedDescription
        }
    }

    func disconnect() {
        connectionID = UUID()
        connectTask?.cancel()
        refreshTask?.cancel()
        discoveryTask?.cancel()
        refreshTask = nil
        discoveryTask = nil
        sessions.forEach { $0.stop() }
        authentication?.stop()
        closeControlDirectory()
        connection = nil
        authentication = nil
        sessions = []
        activeSessionID = nil
        projectDirectory = nil
        projects = []
        selectedProject = nil
        search = ""
        isRefreshing = false
        isRunningGit = false
        gitAttempt = nil
        gitSessionID = nil
        connectionError = nil
        discoveryError = nil
        gitError = nil
        phase = .disconnected
    }

    private func connectionLost() {
        connectTask?.cancel()
        refreshTask?.cancel()
        discoveryTask?.cancel()
        refreshTask = nil
        discoveryTask = nil
        sessions.forEach { $0.stop() }
        closeControlDirectory()
        sessions = []
        activeSessionID = nil
        projectDirectory = nil
        projects = []
        selectedProject = nil
        connection = nil
        isRefreshing = false
        isRunningGit = false
        gitAttempt = nil
        gitSessionID = nil
        phase = .failed
    }

    private func startProjectDiscovery() {
        refresh()
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard let self else { return }
                self.refresh(showProgress: false)
            }
        }
    }

    func refresh(select preferredName: String? = nil, showProgress: Bool = true) {
        guard let connection, phase == .connected else { return }
        if refreshTask != nil, preferredName == nil {
            if showProgress { isRefreshing = true }
            return
        }
        refreshTask?.cancel()
        let attempt = connectionID
        isRefreshing = showProgress
        refreshTask = Task { [weak self] in
            defer {
                if let self, !Task.isCancelled, self.connectionID == attempt {
                    self.refreshTask = nil
                    self.isRefreshing = false
                }
            }
            do {
                let discovered = try await connection.listWorkspace()
                guard let self, !Task.isCancelled, self.connectionID == attempt else { return }
                let found = discovered.projects
                if self.projectDirectory != discovered.directory { self.projectDirectory = discovered.directory }
                if self.projects != found { self.projects = found }
                if self.discoveryError != nil { self.discoveryError = nil }
                if let preferredName, let project = found.first(where: { $0.relativePath == preferredName }) {
                    self.search = ""
                    self.select(project)
                } else if let current = self.selectedProject {
                    let updated = found.first { $0.id == current.id }
                    if current != updated { self.selectedProject = updated }
                } else if self.sessions.isEmpty, let first = found.first {
                    self.select(first)
                }
            } catch {
                guard let self, !Task.isCancelled, self.connectionID == attempt else { return }
                let message = error.localizedDescription
                if self.discoveryError != message { self.discoveryError = message }
            }
        }
    }

    func select(_ project: RemoteProject) {
        selectedProject = project
        if let existing = sessions.last(where: { session in
            terminals[session.id]?.projectID == project.id && terminals[session.id]?.isShell == true && !session.hasEnded
        }) {
            activate(existing)
        } else {
            openShell()
        }
    }

    func openShell() {
        guard let selectedProject, let connection, phase == .connected else { return }
        let session = TerminalSession(
            title: selectedProject.name,
            arguments: connection.shellArguments(for: selectedProject)
        )
        terminals[session.id] = TerminalProject(projectID: selectedProject.id, isShell: true)
        add(session)
    }

    func run(_ command: ArtisanCommand, for project: RemoteProject) {
        guard projects.contains(where: { $0.id == project.id && $0.isLaravel }),
              let connection, phase == .connected else { return }
        let session = TerminalSession(
            title: command.title,
            arguments: connection.artisanArguments(command, project: project)
        )
        terminals[session.id] = TerminalProject(projectID: project.id, isShell: false)
        add(session)
    }

    func gitHubOwners() async throws -> [GitHubOwner] {
        guard let connection, phase == .connected else { throw OmarSSHyError.connectionUnavailable }
        let attempt = connectionID
        let owners = try await connection.gitHubOwners()
        guard connectionID == attempt, phase == .connected else { throw OmarSSHyError.connectionUnavailable }
        return owners
    }

    func gitHubRepositories(for owner: GitHubOwner) async throws -> [GitHubRepository] {
        guard let connection, phase == .connected else { throw OmarSSHyError.connectionUnavailable }
        let attempt = connectionID
        let repositories = try await connection.gitHubRepositories(for: owner)
        guard connectionID == attempt, phase == .connected else { throw OmarSSHyError.connectionUnavailable }
        return repositories
    }

    func run(_ operation: RepositoryOperation, name: String) -> Bool {
        guard let connection, let projectDirectory, phase == .connected, !isRunningGit else { return false }
        do {
            let arguments = try connection.repositoryArguments(operation, in: projectDirectory)
            gitError = nil
            isRunningGit = true
            let attempt = UUID()
            gitAttempt = attempt
            let title: String
            switch operation {
            case .clone, .cloneGitHub: title = "Clonar " + name
            case .initialize: title = "Criar " + name
            }
            let session = TerminalSession(title: title, arguments: arguments) { [weak self] status in
                guard let self, self.gitAttempt == attempt else { return }
                self.gitAttempt = nil
                self.gitSessionID = nil
                self.isRunningGit = false
                if status == 0 {
                    self.refresh(select: name)
                }
            }
            if !session.hasEnded { gitSessionID = session.id }
            add(session)
            return true
        } catch {
            gitError = error.localizedDescription
            return false
        }
    }

    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        if session.id == gitSessionID {
            gitSessionID = nil
            gitAttempt = nil
            isRunningGit = false
        }
        session.stop()
        sessions.remove(at: index)
        terminals.removeValue(forKey: session.id)
        if activeSessionID == session.id {
            if sessions.isEmpty {
                activeSessionID = nil
            } else {
                activate(sessions[min(index, sessions.count - 1)])
            }
        }
    }

    private struct TerminalProject {
        let projectID: String
        let isShell: Bool
    }

    private var terminals: [UUID: TerminalProject] = [:]

    func activate(_ session: TerminalSession) {
        if let projectID = terminals[session.id]?.projectID {
            selectedProject = projects.first { $0.id == projectID }
        }
        activeSessionID = session.id
    }

    private func add(_ session: TerminalSession) {
        sessions.append(session)
        activate(session)
    }

    private func closeControlDirectory() {
        if let controlDirectory {
            try? FileManager.default.removeItem(at: controlDirectory)
        }
        controlDirectory = nil
        terminals = [:]
    }

    private static func makeControlDirectory() throws -> URL {
        var template = Array("/tmp/omarsshy.XXXXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
