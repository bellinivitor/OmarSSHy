import Foundation
import SwiftUI
import OmarSSHyCore

struct ConnectionForm: View {
    @ObservedObject var workspace: Workspace
    @FocusState private var focusHost: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle()
                    .fill(Palette.accent)
                    .frame(width: 31, height: 4)
                    .accessibilityHidden(true)
                Text("Conectar ao\nOmarchy")
                    .font(Palette.type(47, bold: true))
                    .tracking(-1.9)
                    .lineSpacing(-2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, 17)
                Text("Abra os projetos do Omarchy por SSH.")
                    .font(Palette.type(15))
                    .foregroundStyle(Palette.muted)
                    .padding(.top, 9)
                Divider().overlay(Palette.line).padding(.vertical, 23)
                VStack(alignment: .leading, spacing: 14) {
                    FormField(title: "Host ou alias SSH", placeholder: "omarchy", value: $workspace.profile.host)
                        .focused($focusHost)
                    HStack(alignment: .top, spacing: 14) {
                        FormField(title: "Usuário", placeholder: "Opcional", value: $workspace.profile.user)
                        FormField(title: "Porta", placeholder: "22", value: $workspace.profile.port)
                            .frame(width: 99)
                    }
                }
                if let error = workspace.connectionError {
                    Text(error)
                        .foregroundStyle(Palette.accent)
                        .textSelection(.enabled)
                        .padding(.top, 13)
                }
                Button { workspace.connect() } label: {
                    Label("Conectar", systemImage: "arrow.right")
                        .labelStyle(.titleAndIcon)
                        .frame(minWidth: 89)
                }
                .buttonStyle(ActionStyle(primary: true))
                .keyboardShortcut(.defaultAction)
                .padding(.top, 20)
            }
            .frame(maxWidth: 391, alignment: .leading)
            .padding(.top, 54)
            .padding(.horizontal, 46)
            .padding(.bottom, 35)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultFocus($focusHost, true)
        .frame(maxHeight: .infinity)
    }
}

enum RepositorySheet: String, Identifiable {
    case clone, new
    var id: Self { self }
}

struct RepositoryForm: View {
    @ObservedObject var workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @ViewState private var name = ""
    @FocusState private var focusName: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Novo repositório")
                    .font(Palette.type(24, bold: true))
                    .accessibilityAddTraits(.isHeader)
                Text("Destino no Omarchy · " + directoryLabel)
                    .foregroundStyle(Palette.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            FormField(title: "Nome da pasta", placeholder: "meu-projeto", value: $name)
                .focused($focusName)
            if let error = workspace.gitError {
                Text(error)
                    .foregroundStyle(Palette.accent)
                    .textSelection(.enabled)
            }
            HStack(spacing: 9) {
                Spacer()
                Button("Cancelar") { dismiss() }
                    .buttonStyle(ActionStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Criar repositório", action: submit)
                    .buttonStyle(ActionStyle(primary: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(resolvedName.isEmpty)
            }
        }
        .tint(Palette.accent)
        .font(Palette.type(13))
        .foregroundStyle(Palette.ink)
        .padding(25)
        .frame(width: 450)
        .background(Palette.canvas)
        .defaultFocus($focusName, true)
    }

    private var resolvedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var directoryLabel: String {
        let root = workspace.projectDirectory?.displayPath ?? "~/work"
        return resolvedName.isEmpty ? root : root + "/" + resolvedName
    }

    private func submit() {
        if workspace.run(.initialize(name: resolvedName), name: resolvedName) { dismiss() }
    }
}

struct FormField: View {
    let title: String
    let placeholder: String
    @Binding var value: String
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Palette.type(12, bold: true))
                .accessibilityHidden(true)
            TextField(placeholder, text: $value)
                .textFieldStyle(.plain)
                .font(Palette.type(14))
                .padding(.horizontal, 10)
                .frame(height: 37)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(focused ? Palette.accent : Palette.line))
                .focused($focused)
                .accessibilityLabel(title)
        }
    }
}
