import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct KDBXVaultsView: View {
    @ObservedObject var vault: SharedCredentialVault
    @ObservedObject var workspace: KDBXWorkspace
    var embedded = false
    var profileName: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var unlocking: KDBXDatabaseLink?
    @State private var error: String?
    private var links: [KDBXDatabaseLink] { vault.document.kdbxDatabases ?? [] }
    var body: some View {
        Group {
            if embedded { content.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }
            else { content.frame(width: 740, height: 520) }
        }.sheet(item: $unlocking) { link in KDBXUnlockView(link: link, workspace: workspace) }
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { Label("Базы KeePass", systemImage: "lock.rectangle.stack").font(.title2.bold()) }
            if let profileName { Text("Профиль: " + profileName).font(.callout).foregroundStyle(.secondary) }
            Text("Подключи существующий файл KDBX 3.1 или 4.x. SSH Hub читает базу; пароли и сам файл остаются в KeePass. Мастер-пароль не сохраняется.").font(.callout).foregroundStyle(.secondary)
            if vault.isLocked {
                HStack {
                    Label("Учётные данные заблокированы", systemImage: "lock.shield")
                    Spacer()
                    Button("Разблокировать…") {
                        Task { do { try await vault.unlock() } catch { self.error = error.localizedDescription } }
                    }.disabled(vault.authenticating)
                }
            }
            HStack {
                Button("Подключить базу…", systemImage: "plus") { choose(nil) }.disabled(vault.isLocked || links.count >= 20)
                Spacer()
                Button("Заблокировать все", systemImage: "lock") { workspace.cancel() }
            }
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: workspace.runtime.catalog(link.id) == nil ? "lock" : "lock.open").foregroundStyle(.tint)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(link.title).font(.headline)
                                    Text(workspace.runtime.catalog(link.id).map { "Открыта · записей: \($0.count)" } ?? "Заблокирована").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if workspace.runtime.catalog(link.id) == nil { Button("Открыть…") { unlocking = link }.disabled(workspace.busy != nil || vault.isLocked || link.bookmark == nil) }
                                else { Button { workspace.runtime.lock(link.id) } label: { Image(systemName: "lock") }.help("Заблокировать базу") }
                                Button { choose(link) } label: { Image(systemName: "folder") }.help("Выбрать файл заново").disabled(vault.isLocked)
                                Button(role: .destructive) { do { try vault.removeDatabase(link.id); workspace.runtime.lock(link.id) } catch { self.error = error.localizedDescription } } label: { Image(systemName: "link.badge.plus").rotationEffect(.degrees(45)) }.help("Отключить базу от SSH Hub; файл останется на месте").disabled(vault.isLocked)
                            }
                            if link.bookmark == nil { Text("После восстановления архива выбери файл базы заново.").font(.caption).foregroundStyle(.orange) }
                        }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if links.isEmpty { ContentUnavailableView("Нет подключённых баз", systemImage: "lock.rectangle.stack", description: Text("Подключи файл базы. Затем выбери нужную запись KeePass в редакторе подключения или в общих учётных данных.")) }
                }
            }.frame(minHeight: embedded ? 100 : 260)
            if let error = error ?? vault.loadError ?? workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Блокировка приложения, профиля или сеанса macOS закрывает базы. При изменении файла требуется повторное открытие. Файлы ключей и база не входят в архив SSH Hub.").font(.caption).foregroundStyle(.secondary)
            if !embedded { HStack { Spacer(); Button("Готово") { dismiss() }.keyboardShortcut(.cancelAction) } }
        }.padding(22)
    }
    private func choose(_ replacing: KDBXDatabaseLink?) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.title = "Подключить базу KeePass"; panel.allowedContentTypes = [UTType(filenameExtension: "kdbx") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { let link = try KDBXWorkspace.link(url, replacing: replacing); try vault.saveDatabase(link); workspace.runtime.lock(link.id); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

private struct KDBXUnlockView: View {
    let link: KDBXDatabaseLink
    @ObservedObject var workspace: KDBXWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var usePassword = true
    @State private var keyFile: URL?
    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label(link.title, systemImage: "lock.open").font(.title2.bold())
            Toggle("Использовать мастер-пароль", isOn: $usePassword).toggleStyle(.checkbox)
            if usePassword { PasswordEntryView(prompt: "Мастер-пароль базы KeePass", text: $password, showsGenerator: false) }
            HStack {
                Text(keyFile?.lastPathComponent ?? "Ключевой файл не выбран").font(.caption).lineLimit(2)
                Spacer()
                Button("Ключевой файл…") { let panel = NSOpenPanel(); panel.canChooseDirectories = false; if panel.runModal() == .OK { keyFile = panel.url } }
                if keyFile != nil { Button { keyFile = nil } label: { Image(systemName: "xmark") }.help("Убрать ключевой файл") }
            }
            Text("Мастер-пароль и ключевой файл используются только для открытия базы. После блокировки их потребуется указать снова.").font(.caption).foregroundStyle(.secondary)
            if let error = workspace.error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                if workspace.busy != nil { ProgressView().controlSize(.small); Text("Открываем базу…").font(.caption) }
                Spacer()
                Button("Отмена") { workspace.cancel(); password = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Открыть") {
                    let value = usePassword ? password : nil; password = ""
                    Task { await workspace.open(link, password: value, keyFile: keyFile); if workspace.runtime.catalog(link.id) != nil { dismiss() } }
                }.buttonStyle(.borderedProminent).disabled(workspace.busy != nil || (!usePassword && keyFile == nil))
            }
        }.padding(22).frame(width: 540).interactiveDismissDisabled(workspace.busy != nil)
            .onDisappear { password = ""; if workspace.busy != nil { workspace.cancel() } }
    }
}

struct KDBXEntryPicker: View {
    let links: [KDBXDatabaseLink]
    @ObservedObject var workspace: KDBXWorkspace
    let onSelect: (KDBXReference, KDBXEntryInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var unlocking: KDBXDatabaseLink?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Запись KeePass", systemImage: "key").font(.title2.bold())
            TextField("Название, пользователь или группа", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(links) { link in
                        Text(link.title).font(.headline)
                        if let entries = workspace.runtime.catalog(link.id) {
                            ForEach(entries.filter { query.isEmpty || ($0.title + " " + $0.username + " " + $0.group).localizedCaseInsensitiveContains(query) }) { entry in
                                Button { onSelect(KDBXReference(databaseID: link.id, entryID: entry.id), entry); dismiss() } label: {
                                    HStack { Image(systemName: "key"); VStack(alignment: .leading, spacing: 3) { Text(entry.title.isEmpty ? "Без названия" : entry.title); Text([entry.group,entry.username].filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary) }; Spacer(); if entry.expired { Text("Истёк срок").foregroundStyle(.orange).font(.caption) } }.padding(9).contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(entry.expired)
                            }
                        } else { HStack { Text("База заблокирована").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Открыть…") { unlocking = link }.disabled(workspace.busy != nil || link.bookmark == nil) } }
                    }
                    if links.isEmpty { Text("Сначала подключи базу через «Базы KeePass…».").foregroundStyle(.secondary) }
                }
            }.frame(minHeight: 280)
            HStack { Spacer(); Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(22).frame(width: 620, height: 460)
            .sheet(item: $unlocking) { KDBXUnlockView(link: $0, workspace: workspace) }
    }
}
