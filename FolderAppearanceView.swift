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
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Логотип папки").font(.title2).bold()
            Text(path).foregroundStyle(.secondary)
            HStack(spacing: 18) {
                Button(action: chooseLogo) {
                    FolderIcon(appearance: appearance, size: 64).padding(12)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14))
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .blue) }
                }.buttonStyle(.plain).help("Выбрать логотип папки").accessibilityLabel("Выбрать логотип папки")
                VStack(alignment: .leading, spacing: 10) {
                    Text("Нажми на значок, чтобы выбрать изображение.").font(.callout)
                    Text("PNG, JPEG или WebP").font(.caption).foregroundStyle(.secondary)
                    if appearance.logo != nil { Button("Убрать логотип") { appearance.logo = nil }.buttonStyle(.link) }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Отмена", role: .cancel) { dismiss() }; Button("Сохранить") {
                store.setFolderAppearance(appearance, path: path); dismiss()
            }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 460).onAppear { appearance = store.folderAppearance(path) }
    }
    private func chooseLogo() {
        let panel = NSOpenPanel(); panel.title = "Логотип папки"; panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { appearance.logo = try ConnectionLogo.load(url); error = nil } catch { self.error = error.localizedDescription }
    }
}
