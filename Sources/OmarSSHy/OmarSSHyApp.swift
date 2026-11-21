import AppKit
import SwiftUI
import OmarSSHyCore

// Use the property wrapper on command-line SDKs that also declare the State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

@main
struct OmarSSHyApp: App {
    @NSApplicationDelegateAdaptor(OmarSSHyAppDelegate.self) private var delegate
    @StateObject private var workspace = Workspace()

    var body: some Scene {
        Window("OmarSSHy", id: "workspace") {
            WorkspaceView(workspace: workspace)
                .frame(minWidth: 790, minHeight: 555)
                .preferredColorScheme(.light)
                .task { workspace.connectSavedProfile() }
                .onDisappear { workspace.disconnect() }
        }
        .defaultSize(width: 1110, height: 715)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Novo terminal") { workspace.openShell() }
                    .keyboardShortcut("t")
                    .disabled(workspace.selectedProject == nil)
                Button("Atualizar projetos") { workspace.refresh() }
                    .keyboardShortcut("r")
                    .disabled(workspace.phase != .connected)
            }
        }
    }
}

final class OmarSSHyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

enum Palette {
    static let canvas = Color.white
    static let panel = Color(red: 0.969, green: 0.969, blue: 0.973)
    static let ink = Color(red: 0.093, green: 0.093, blue: 0.112)
    static let muted = Color(red: 0.32, green: 0.33, blue: 0.36)
    static let line = Color(red: 0.875, green: 0.878, blue: 0.89)
    static let accent = Color(red: 228.0 / 255, green: 0, blue: 43.0 / 255)
    static let tint = Color(red: 1, green: 0.939, blue: 0.947)

    static func type(_ size: CGFloat, bold: Bool = false) -> Font {
        .custom(bold ? "HelveticaNeue-Bold" : "HelveticaNeue", size: size)
    }
}

struct ActionStyle: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Palette.type(13, bold: true))
            .padding(.horizontal, 13)
            .frame(minHeight: 34)
            .foregroundStyle(primary ? Color.white : Palette.ink)
            .background(primary ? Palette.accent : Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                if !primary {
                    RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line)
                }
            }
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.42)
            .contentShape(Rectangle())
    }
}

struct WorkspaceView: View {
    @ObservedObject var workspace: Workspace
    @ViewState private var repositorySheet: RepositorySheet?
    @ViewState private var pendingArtisan: ArtisanConfirmation?

    private struct ArtisanConfirmation {
        let command: ArtisanCommand
        let project: RemoteProject
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 250)
            Rectangle().fill(Palette.line).frame(width: 1)
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(Palette.type(13))
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .tint(Palette.accent)
        .sheet(item: $repositorySheet) { mode in
            switch mode {
            case .clone:
                CloneSheet(workspace: workspace)
            case .new:
                RepositoryForm(workspace: workspace)
            }
        }
        .alert("Executar comando Artisan?", isPresented: showConfirmation, presenting: pendingArtisan) { pending in
            Button("Cancelar", role: .cancel) { pendingArtisan = nil }
            Button("Executar", role: .destructive) {
                workspace.run(pending.command, for: pending.project)
                pendingArtisan = nil
            }
        } message: { pending in
            Text(pending.command.command + " em " + pending.project.name)
        }
    }

    private var showConfirmation: Binding<Bool> {
        Binding(get: { pendingArtisan != nil }, set: { if !$0 { pendingArtisan = nil } })
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "terminal")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 31, height: 31)
                    .foregroundStyle(.white)
                    .background(Palette.accent, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                Text("OmarSSHy")
                    .font(Palette.type(23, bold: true))
                    .tracking(-0.7)
            }
            .padding(.horizontal, 20)
            .frame(height: 71)
            Divider().overlay(Palette.line)
            projectList
                .frame(maxHeight: .infinity, alignment: .top)
            Divider().overlay(Palette.line)
            connectionFooter
        }
        .background(Palette.panel)
    }

    private var projectList: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Text("Projetos")
                    .font(Palette.type(13, bold: true))
                if workspace.phase == .connected, workspace.discoveryError == nil, !workspace.projects.isEmpty {
                    Text(String(workspace.projects.count))
                        .font(Palette.type(11))
                        .foregroundStyle(Palette.muted)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 4))
                        .accessibilityLabel("\(workspace.projects.count) projetos")
                }
                Spacer()
                if workspace.phase == .connected {
                    if workspace.isRefreshing {
                        ProgressView().controlSize(.small).accessibilityLabel("Atualizando projetos")
                    } else {
                        Button { workspace.refresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .frame(width: 25, height: 24)
                        }
                        .buttonStyle(.plain)
                        .help("Atualizar projetos")
                        .accessibilityLabel("Atualizar projetos")
                    }
                }
            }
            if workspace.phase == .connected {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Buscar projeto", text: $workspace.search)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Buscar projeto")
                }
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
                if let error = workspace.discoveryError {
                    Text(error)
                        .font(Palette.type(12))
                        .foregroundStyle(Palette.accent)
                        .textSelection(.enabled)
                }
                if workspace.visibleProjects.isEmpty {
                    Text(emptyProjectListLabel)
                        .font(Palette.type(12))
                        .foregroundStyle(Palette.muted)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(workspace.visibleProjects) { project in
                                projectRow(project)
                            }
                        }
                    }
                    .scrollIndicators(.automatic)
                }
            } else {
                Text("Conecte-se para listar os projetos.")
                    .font(Palette.type(12))
                    .foregroundStyle(Palette.muted)
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 14)
    }

    private var emptyProjectListLabel: String {
        if workspace.isRefreshing { return "Buscando projetos…" }
        if !workspace.projects.isEmpty { return "Nenhum resultado." }
        if let directory = workspace.projectDirectory { return "Nenhum projeto em " + directory.displayPath + "." }
        return "Nenhum projeto encontrado."
    }

    private func projectRow(_ project: RemoteProject) -> some View {
        let selected = workspace.selectedProject?.id == project.id
        let group = project.relativePath.lastIndex(of: "/").map { String(project.relativePath[..<$0]) }
        return Button { workspace.select(project) } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "folder.fill" : "folder")
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(Palette.type(13, bold: selected))
                        .lineLimit(1)
                    if let group {
                        Text(group)
                            .font(Palette.type(10))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 3)
                if project.isLaravel {
                    Text("Laravel")
                        .font(Palette.type(10, bold: true))
                        .foregroundStyle(Palette.accent)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: group == nil ? 34 : 43)
            .background(selected ? Palette.tint : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(project.displayPath)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var connectionFooter: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(workspace.phase == .connected ? Palette.accent : Palette.muted.opacity(0.62))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(connectionLabel).font(Palette.type(11, bold: true))
                if !workspace.profile.host.isEmpty {
                    Text(workspace.profile.destinationLabel)
                        .font(Palette.type(11))
                        .foregroundStyle(Palette.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
            if workspace.phase == .connected {
                Button { workspace.disconnect() } label: {
                    Image(systemName: "power").frame(width: 25, height: 25)
                }
                .buttonStyle(.plain)
                .help("Desconectar")
                .accessibilityLabel("Desconectar")
            }
        }
        .padding(.horizontal, 17)
        .frame(height: 58)
    }

    private var connectionLabel: String {
        switch workspace.phase {
        case .disconnected: "Desconectado"
        case .connecting: "Conectando"
        case .connected: "Conectado"
        case .failed: "Conexão encerrada"
        }
    }

    @ViewBuilder private var detail: some View {
        switch workspace.phase {
        case .disconnected:
            ConnectionForm(workspace: workspace)
        case .connecting, .failed:
            authenticationScreen
        case .connected:
            connectedScreen
        }
    }

    private var authenticationScreen: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(workspace.phase == .failed ? "Conexão encerrada" : "Conectando ao Omarchy")
                        .font(Palette.type(25, bold: true))
                    Text(workspace.phase == .failed ? "Confira abaixo a saída do SSH." : "Se o SSH pedir confirmação ou senha, responda no terminal.")
                        .foregroundStyle(Palette.muted)
                }
                Spacer()
                Button(workspace.phase == .failed ? "Editar conexão" : "Cancelar") { workspace.disconnect() }
                    .buttonStyle(ActionStyle())
            }
            if let authentication = workspace.authentication {
                TerminalSurface(session: authentication)
                    .padding(10)
                    .background(Palette.canvas)
                    .overlay(Rectangle().strokeBorder(Palette.line))
            }
        }
        .padding(25)
    }

    private var connectedScreen: some View {
        VStack(alignment: .leading, spacing: 0) {
            workspaceHeader
            Divider().overlay(Palette.line)
            if workspace.sessions.isEmpty {
                emptyTerminal
            } else {
                terminalTabs
                Divider().overlay(Palette.line)
                if let session = workspace.activeSession {
                    TerminalPane(session: session)
                }
            }
        }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text(workspace.selectedProject?.name ?? "Projetos")
                    .font(Palette.type(25, bold: true))
                    .tracking(-0.5)
                    .lineLimit(1)
                Text(workspace.selectedProject?.displayPath ?? workspace.projectDirectory?.displayPath ?? "Omarchy")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 10)
            artisanMenu
            Button { openRepository(.clone) } label: {
                Label("Clonar", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(ActionStyle())
            .disabled(workspace.isRunningGit || workspace.projectDirectory == nil)
            Button { openRepository(.new) } label: {
                Label("Novo repo", systemImage: "plus")
            }
            .buttonStyle(ActionStyle(primary: true))
            .disabled(workspace.isRunningGit || workspace.projectDirectory == nil)
        }
        .padding(.horizontal, 23)
        .frame(height: 82)
    }

    private func openRepository(_ mode: RepositorySheet) {
        workspace.gitError = nil
        repositorySheet = mode
    }

    private var artisanMenu: some View {
        let project = workspace.selectedProject
        let enabled = project?.isLaravel == true

        return Menu {
            ForEach(ArtisanCommand.allCases) { command in
                Button {
                    guard let project else { return }
                    if command.requiresConfirmation {
                        pendingArtisan = ArtisanConfirmation(command: command, project: project)
                    } else {
                        workspace.run(command, for: project)
                    }
                } label: {
                    Label(command.title, systemImage: command.icon)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text("Artisan")
                    .font(Palette.type(13, bold: true))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line))
            .opacity(enabled ? 1 : 0.42)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!enabled)
        .help(enabled ? "Comandos Artisan" : "Disponível em projetos Laravel")
    }

    private var terminalTabs: some View {
        HStack(spacing: 6) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 3) {
                        ForEach(workspace.sessions) { session in
                            SessionTab(
                                session: session,
                                selected: session.id == workspace.activeSessionID,
                                activate: { workspace.activate(session) },
                                close: { workspace.close(session) }
                            )
                            .id(session.id)
                        }
                    }
                    .padding(.leading, 17)
                }
                .scrollIndicators(.hidden)
                .onChange(of: workspace.activeSessionID) { _, newValue in
                    if let newValue { proxy.scrollTo(newValue, anchor: .trailing) }
                }
            }
            Button { workspace.openShell() } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(workspace.selectedProject == nil)
            .accessibilityLabel("Novo terminal")
            .help("Novo terminal")
            .padding(.trailing, 13)
        }
        .frame(height: 42)
        .background(Palette.panel)
    }

    private var emptyTerminal: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: "terminal")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(workspace.selectedProject == nil ? "Selecione um projeto" : "Abra um terminal")
                .font(Palette.type(24, bold: true))
            if workspace.selectedProject != nil {
                Button("Novo terminal") { workspace.openShell() }
                    .buttonStyle(ActionStyle(primary: true))
                    .padding(.top, 5)
            } else if workspace.projects.isEmpty, !workspace.isRefreshing, let directory = workspace.projectDirectory {
                Text("Clone ou crie um repositório em " + directory.displayPath + " para começar.")
                    .foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(35)
    }
}

private struct SessionTab: View {
    @ObservedObject var session: TerminalSession
    var selected: Bool
    var activate: () -> Void
    var close: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: activate) {
                Label(session.title, systemImage: icon)
                    .font(Palette.type(12, bold: selected))
                    .lineLimit(1)
                    .frame(minHeight: 32)
                    .padding(.leading, 8)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(session.title)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 23, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Fechar \(session.title)")
            .help("Fechar terminal")
        }
        .foregroundStyle(selected ? Palette.ink : Palette.muted)
        .padding(.horizontal, 2)
        .background(alignment: .bottom) {
            if selected {
                Palette.canvas.overlay(alignment: .bottom) {
                    Rectangle().fill(Palette.accent).frame(height: 2)
                }
            }
        }
    }

    private var icon: String {
        if !session.hasEnded { return "terminal" }
        return session.exitStatus == 0 ? "checkmark" : "exclamationmark.circle"
    }
}

private struct TerminalPane: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            TerminalSurface(session: session)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.hasEnded {
                Divider().overlay(Palette.line)
                HStack(spacing: 7) {
                    Image(systemName: session.exitStatus == 0 ? "checkmark.circle" : "exclamationmark.circle")
                    Text(exitLabel)
                    Spacer()
                }
                .foregroundStyle(session.exitStatus == 0 ? Palette.muted : Palette.accent)
                .font(Palette.type(12))
                .padding(.horizontal, 16)
                .frame(height: 31)
                .background(Palette.panel)
            }
        }
    }

    private var exitLabel: String {
        if session.exitStatus == 0 { return "Sessão concluída" }
        if let exitStatus = session.exitStatus { return "Sessão encerrada (código \(exitStatus))" }
        return "Sessão encerrada"
    }
}
