import SwiftUI

struct SystemSSHAliasView: View {
    let entry: SSHAlias
    @EnvironmentObject private var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var installedName: String?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HubSheetHeader(title: "Установить SSH-алиас на Mac", subtitle: store.title(entry), icon: "terminal")
            if let installedName {
                Text("Алиас готов. Эту команду можно выполнить в Терминале.")
                HStack {
                    Text("ssh " + installedName).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Копировать", systemImage: "doc.on.doc") { store.copy("ssh " + installedName) }
                }
                HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction) }
            } else {
                TextField("Имя SSH-алиаса", text: $name).textFieldStyle(.roundedBorder)
                Text("SSH Hub добавит алиас в ~/.ssh/config. Если для входа выбран ключ, его копия будет храниться в ~/.ssh и доступна Терминалу после закрытия базы. Пароль при необходимости запросит сам ssh.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if entry.value("ProxyJump") != nil {
                    Text("Промежуточный сервер должен быть доступен из обычного ssh.").font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    Spacer()
                    Button("Отмена", role: .cancel) { dismiss() }
                    Button("Установить") { install() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(!SSHConfig.matches(name.trimmingCharacters(in: .whitespaces), "^[A-Za-z0-9_][A-Za-z0-9_.-]*$"))
                }
            }
        }.padding(24).frame(width: 490)
            .onAppear {
                let candidate = entry.sshAlias ?? entry.name
                name = SSHConfig.matches(candidate, "^[A-Za-z0-9_][A-Za-z0-9_.-]*$") ? candidate : ""
            }
    }

    private func install() {
        do {
            guard !AppAccess.shared.locked, !store.endingWorkspace, PortableSecretBridge.active,
                  let current = store.profileEntries.first(where: { $0.favoriteID == entry.favoriteID && !$0.isQuickConnection }) else {
                throw VaultError.locked
            }
            let prepared = try store.credentialVault().runtime.preparedEntry(current, config: store.config.url)
            let alias = name.trimmingCharacters(in: .whitespaces)
            try SystemSSHAlias.install(prepared, name: alias, config: SSHConfig())
            installedName = alias
        } catch { self.error = error.localizedDescription }
    }
}
