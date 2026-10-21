import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct FolderStyleTarget: Identifiable { let path: String; var id: String { path } }
struct FolderIcon: View {
    let appearance: ConnectionAppearance
    var size: CGFloat = 18
    var body: some View {
        Group {
            if let data = appearance.logo, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else { Image(systemName: "folder.fill").resizable().scaledToFit().foregroundStyle(.yellow) }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.15))
    }
}
struct FolderAppearanceView: View {
    let path: String
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var appearance = ConnectionAppearance()
    @State private var name = ""
    @State private var expectedProfiles: HubProfiles?
    @State private var expectedGroups: [String: String] = [:]
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Редактирование папки").font(.title2).bold()
            Text(path).foregroundStyle(.secondary)
            TextField("Название папки", text: $name).textFieldStyle(.roundedBorder)
            FolderAppearanceFields(appearance: $appearance)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }; Button("Сохранить") {
                do {
                    guard !AppAccess.shared.locked, !store.endingWorkspace, expectedProfiles == store.profiles, expectedGroups == store.groups else { throw ConfigError.message("Папки изменились. Открой редактор заново.") }
                    let plan = try FolderRenamePlan(profiles: store.profiles, groups: store.groups, keys: Set(store.profileEntries.map(\.favoriteID)), old: path, name: name, appearance: appearance)
                    store.applyFolderRename(plan); dismiss()
                } catch { self.error = error.localizedDescription }
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 460).dismissOnOutsideClick().onAppear { appearance = store.folderAppearance(path); name = ConnectionTree.components(path).last ?? ""; expectedProfiles = store.profiles; expectedGroups = store.groups }
    }
}

struct FolderAppearanceFields: View {
    @Binding var appearance: ConnectionAppearance
    @State private var error: String?
    @State private var choosingWebsite = false
    var body: some View {
        HStack(spacing: 18) {
            Button(action: chooseLogo) {
                FolderIcon(appearance: appearance, size: 64).padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                    .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .blue) }
            }.buttonStyle(.plain).help("Выбрать логотип папки").accessibilityLabel("Выбрать логотип папки")
            VStack(alignment: .leading, spacing: 10) {
                Text("PNG, JPEG или WebP").font(.caption).foregroundStyle(.secondary)
                Button("Иконка с сайта…", systemImage: "globe") { choosingWebsite = true }.controlSize(.small)
                if appearance.logo != nil { Button("Убрать логотип") { appearance.logo = nil }.buttonStyle(.link) }
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }.sheet(isPresented: $choosingWebsite) {
            WebsiteIconView(address: "") { data in appearance.logo = data; error = nil }
        }
    }
    private func chooseLogo() {
        let panel = NSOpenPanel(); panel.title = "Логотип папки"; panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { appearance.logo = try ConnectionLogo.load(url); error = nil } catch { self.error = error.localizedDescription }
    }
}
