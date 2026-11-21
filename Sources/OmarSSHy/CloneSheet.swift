import Foundation
import SwiftUI
import OmarSSHyCore

struct CloneSheet: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var source: Source?

    private enum Source { case gitHub, publicLink }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Palette.line)

            switch source {
            case nil:
                sourceChooser
            case .gitHub:
                GitHubCloneForm(workspace: workspace)
            case .publicLink:
                PublicLinkCloneForm(workspace: workspace)
            }
        }
        .frame(width: 526)
        .font(Palette.type(13))
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .tint(Palette.accent)
    }

    private var header: some View {
        HStack(spacing: 13) {
            if source != nil {
                Button {
                    workspace.gitError = nil
                    source = nil
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Voltar à escolha da origem")
                .help("Voltar")
            } else {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 40, height: 40)
                    .background(Palette.tint, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Palette.type(24, bold: true))
                    .tracking(-0.55)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle)
                    .foregroundStyle(Palette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
    }

    private var title: String {
        switch source {
        case nil: "Clonar repositório"
        case .gitHub: "Clonar do GitHub"
        case .publicLink: "Clonar por link público"
        }
    }

    private var subtitle: String {
        switch source {
        case nil: "Escolha a origem do repositório."
        case .gitHub: "Use a conta autenticada no Omarchy."
        case .publicLink: "Use o endereço Git de um repositório público."
        }
    }

    private var sourceChooser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                CloneSourceCard(
                    title: "Conta do GitHub",
                    detail: "Escolha uma conta ou organização e um repositório.",
                    icon: "person.crop.circle"
                ) { source = .gitHub }
                CloneSourceCard(
                    title: "Link público",
                    detail: "Cole o endereço Git para clonar diretamente.",
                    icon: "link"
                ) { source = .publicLink }
            }
            .padding(24)

            Divider().overlay(Palette.line)
            HStack {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(ActionStyle())
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
    }
}

private struct CloneSourceCard: View {
    let title: String
    let detail: String
    let icon: String
    let action: () -> Void

    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 38, height: 38)
                    .background(Palette.tint, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(Palette.type(15, bold: true))
                    Text(detail)
                        .font(Palette.type(12))
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 10)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovered ? Palette.accent : Palette.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Palette.panel : Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

private struct GitHubCloneForm: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var owners: CloneLoad<[GitHubOwner]> = .loading
    @ViewState private var repositories: CloneLoad<[GitHubRepository]> = .loading
    @ViewState private var owner: GitHubOwner?
    @ViewState private var selection: GitHubRepository?
    @ViewState private var query = ""
    @ViewState private var folder = ""
    @ViewState private var ownerMenuPresented = false
    @ViewState private var ownerAttempt = 0
    @ViewState private var repositoryAttempt = 0
    @FocusState private var searchFocused: Bool

    private enum CloneLoad<Value> {
        case loading
        case loaded(Value)
        case failed(String)
    }

    private struct RepositoryRequest: Hashable {
        let owner: GitHubOwner
        let attempt: Int
    }

    var body: some View {
        let request = repositoryRequest
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                switch owners {
                case .loading:
                    loading("Carregando conta e organizações…")
                case .failed(let message):
                    error(message) { ownerAttempt += 1 }
                case .loaded(let available):
                    if let owner {
                        ownerField(available, selection: owner)
                        repositoryPicker
                        FormField(
                            title: "Nome da pasta",
                            placeholder: selection?.name ?? "Selecione um repositório",
                            value: $folder
                        )
                        .disabled(selection == nil)
                    } else {
                        status("Nenhuma conta disponível", icon: "person.crop.circle")
                    }
                }

                if let error = workspace.gitError {
                    Text(error)
                        .foregroundStyle(Palette.accent)
                        .textSelection(.enabled)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)

            CloneFooter(
                workspace: workspace,
                folder: resolvedFolder,
                canClone: selection != nil && !resolvedFolder.isEmpty
            ) {
                guard let selection else { return }
                let operation = RepositoryOperation.cloneGitHub(repository: selection, name: resolvedFolder)
                if workspace.run(operation, name: resolvedFolder) { dismiss() }
            }
        }
        .task(id: ownerAttempt) { await fetchOwners() }
        .task(id: request) { await fetchRepositories(request) }
        .onChange(of: query) { _, _ in
            if let selection, !filteredRepositories.contains(selection) {
                self.selection = nil
                folder = ""
            }
        }
        .defaultFocus($searchFocused, true)
    }

    private var repositoryRequest: RepositoryRequest? {
        owner.map { RepositoryRequest(owner: $0, attempt: repositoryAttempt) }
    }

    private var filteredRepositories: [GitHubRepository] {
        guard case .loaded(let available) = repositories else { return [] }
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? available : available.filter {
            $0.fullName.localizedStandardContains(search)
                || ($0.description?.localizedStandardContains(search) ?? false)
        }
    }

    private var resolvedFolder: String {
        let custom = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? selection?.name ?? "" : custom
    }

    private func ownerField(_ options: [GitHubOwner], selection: GitHubOwner) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Conta ou organização")
                .font(Palette.type(12, bold: true))
            Button {
                ownerMenuPresented.toggle()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: ownerIcon(selection))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                    Text(selection.login)
                        .font(Palette.type(14, bold: true))
                        .lineLimit(1)
                    Text(selection.kind == .personal ? "Conta pessoal" : "Organização")
                        .font(Palette.type(12))
                        .foregroundStyle(Palette.muted)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Palette.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 39)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Palette.line).allowsHitTesting(false))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Conta ou organização")
            .accessibilityValue(selection.login)
            .popover(isPresented: $ownerMenuPresented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 3) {
                        ForEach(options) { option in
                            ownerOption(option, selected: option == selection)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 260, height: CGFloat(min(options.count, 7) * 34 + 12))
                .padding(4)
            }
        }
    }

    private func ownerOption(_ option: GitHubOwner, selected: Bool) -> some View {
        Button {
            ownerMenuPresented = false
            selectOwner(option)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: ownerIcon(option)).accessibilityHidden(true)
                Text(option.login).lineLimit(1)
                Spacer(minLength: 8)
                if selected { Image(systemName: "checkmark").accessibilityHidden(true) }
            }
            .font(Palette.type(13, bold: selected))
            .foregroundStyle(selected ? Palette.accent : Palette.ink)
            .padding(.horizontal, 9)
            .frame(height: 31)
            .background(selected ? Palette.tint : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func ownerIcon(_ owner: GitHubOwner) -> String {
        owner.kind == .personal ? "person.crop.circle" : "building.2"
    }

    private var repositoryPicker: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Repositórios")
                .font(Palette.type(12, bold: true))
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Palette.muted)
                    .accessibilityHidden(true)
                TextField("Buscar repositório", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .accessibilityLabel("Buscar repositório")
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
            }
            .padding(.horizontal, 10)
            .frame(height: 35)
            .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(searchFocused ? Palette.accent : Palette.line))
            repositoryContent
                .frame(height: 204)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Palette.line).allowsHitTesting(false))
        }
    }

    @ViewBuilder private var repositoryContent: some View {
        switch repositories {
        case .loading:
            loading("Carregando repositórios…").padding(14)
        case .failed(let message):
            error(message) { repositoryAttempt += 1 }
                .padding(14)
        case .loaded(let available):
            let filtered = filteredRepositories
            if available.isEmpty {
                status("Nenhum repositório disponível", icon: "folder")
                    .padding(14)
            } else if filtered.isEmpty {
                status("Nenhum repositório encontrado", icon: "magnifyingglass")
                    .padding(14)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filtered) { repository in
                                repositoryRow(repository)
                                    .id(repository.id)
                                if repository.id != filtered.last?.id {
                                    Divider()
                                        .overlay(Palette.line)
                                        .padding(.leading, 12)
                                }
                            }
                        }
                        .padding(4)
                    }
                    .onChange(of: selection?.id) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
            }
        }
    }

    private func repositoryRow(_ repository: GitHubRepository) -> some View {
        let selected = selection == repository
        return Button { selectRepository(repository) } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Palette.accent : Palette.muted)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(repository.name)
                        .font(Palette.type(13, bold: true))
                        .lineLimit(1)
                    if let description = repository.description, !description.isEmpty {
                        Text(description)
                            .font(Palette.type(11))
                            .foregroundStyle(Palette.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if repository.isPrivate {
                    Label("Privado", systemImage: "lock")
                        .font(Palette.type(11))
                        .foregroundStyle(Palette.muted)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(minHeight: 40)
            .background(selected ? Palette.tint : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(repository.fullName)
    }

    private func loading(_ title: String) -> some View {
        HStack(spacing: 9) {
            ProgressView().controlSize(.small)
            Text(title).foregroundStyle(Palette.muted)
        }
        .accessibilityElement(children: .combine)
    }

    private func status(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .foregroundStyle(Palette.muted)
    }

    private func error(_ message: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(message).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.circle").foregroundStyle(Palette.accent)
            }
            Button("Tentar novamente", action: retry)
                .buttonStyle(ActionStyle())
        }
    }

    private func selectOwner(_ option: GitHubOwner) {
        guard owner != option else { return }
        owner = option
        repositories = .loading
        selection = nil
        folder = ""
        query = ""
        workspace.gitError = nil
    }

    private func selectRepository(_ repository: GitHubRepository) {
        guard selection != repository else { return }
        selection = repository
        folder = ""
        workspace.gitError = nil
    }

    private func moveSelection(by offset: Int) -> KeyPress.Result {
        let available = filteredRepositories
        guard !available.isEmpty else { return .ignored }
        let current = selection.flatMap { available.firstIndex(of: $0) }
        let next = current.map { min(max(0, $0 + offset), available.count - 1) }
            ?? (offset > 0 ? 0 : available.count - 1)
        selectRepository(available[next])
        return .handled
    }

    private func fetchOwners() async {
        guard !Task.isCancelled else { return }
        owners = .loading
        do {
            let available = try await workspace.gitHubOwners()
            guard !Task.isCancelled else { return }
            owners = .loaded(available)
            if let first = available.first { selectOwner(first) }
        } catch {
            guard !Task.isCancelled else { return }
            owners = .failed(error.localizedDescription)
        }
    }

    private func fetchRepositories(_ request: RepositoryRequest?) async {
        guard let request, !Task.isCancelled, repositoryRequest == request else { return }
        repositories = .loading
        do {
            let available = try await workspace.gitHubRepositories(for: request.owner)
            guard !Task.isCancelled, repositoryRequest == request else { return }
            repositories = .loaded(available)
        } catch {
            guard !Task.isCancelled, repositoryRequest == request else { return }
            repositories = .failed(error.localizedDescription)
        }
    }
}

private struct PublicLinkCloneForm: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var link = ""
    @ViewState private var folder = ""
    @FocusState private var linkFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                FormField(title: "URL Git", placeholder: "https://github.com/conta/projeto.git", value: $link)
                    .focused($linkFocused)
                FormField(
                    title: "Nome da pasta",
                    placeholder: suggestedFolder.isEmpty ? "meu-projeto" : suggestedFolder,
                    value: $folder
                )

                if let error = workspace.gitError {
                    Text(error)
                        .foregroundStyle(Palette.accent)
                        .textSelection(.enabled)
                }
            }
            .padding(24)

            CloneFooter(
                workspace: workspace,
                folder: resolvedFolder,
                canClone: !cleanedLink.isEmpty && !resolvedFolder.isEmpty
            ) {
                if workspace.run(.clone(url: cleanedLink, name: resolvedFolder), name: resolvedFolder) {
                    dismiss()
                }
            }
        }
        .defaultFocus($linkFocused, true)
    }

    private var cleanedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var suggestedFolder: String {
        let path: String
        if let components = URLComponents(string: cleanedLink), components.host != nil {
            path = components.path
        } else if let colon = cleanedLink.firstIndex(of: ":") {
            path = String(cleanedLink[cleanedLink.index(after: colon)...])
        } else {
            return ""
        }
        guard let component = path.split(separator: "/").last else { return "" }
        return component.hasSuffix(".git") ? String(component.dropLast(4)) : String(component)
    }

    private var resolvedFolder: String {
        let custom = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        return custom.isEmpty ? suggestedFolder : custom
    }
}

private struct CloneFooter: View {
    @ObservedObject var workspace: Workspace
    let folder: String
    let canClone: Bool
    let clone: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Divider().overlay(Palette.line)

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Destino no Omarchy")
                        .font(Palette.type(11, bold: true))
                        .foregroundStyle(Palette.muted)
                    Text(path)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(path)
                }
                Spacer(minLength: 4)
                Button("Cancelar") { dismiss() }
                    .buttonStyle(ActionStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Clonar", action: clone)
                    .buttonStyle(ActionStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone || workspace.phase != .connected || workspace.projectDirectory == nil || workspace.isRunningGit)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
        }
        .background(Palette.panel)
    }

    private var path: String {
        let root = workspace.projectDirectory?.displayPath ?? "~/work"
        return folder.isEmpty ? root : root + "/" + folder
    }
}
