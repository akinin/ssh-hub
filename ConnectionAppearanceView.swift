import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ImageIO


struct ConnectionIcon: View {
    let appearance: ConnectionAppearance
    var size: CGFloat = 24
    var symbol: String = "server.rack"
    var body: some View {
        Group {
            if let data = appearance.logo, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: symbol).resizable().scaledToFit().padding(size * 0.12).foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }
}

struct ConnectionAppearanceFields: View {
    @Binding var appearance: ConnectionAppearance
    let fallback: String
    @State private var error: String?
    var body: some View {
        HStack(spacing: 16) {
            VStack(spacing: 6) {
                Button { chooseLogo() } label: {
                    ConnectionIcon(appearance: appearance, size: 54).padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .bottomTrailing) { Image(systemName: "pencil.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .blue) }
                }.buttonStyle(.plain).help("Выбрать логотип").accessibilityLabel("Выбрать логотип")
                if appearance.logo != nil {
                    Button("Убрать логотип") { appearance.logo = nil }.buttonStyle(.link).font(.caption)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Название записи").font(.caption).foregroundStyle(.secondary)
                TextField("Название", text: $appearance.name, prompt: Text(fallback.isEmpty ? "Например, Домашний сервер" : fallback))
                    .textFieldStyle(.roundedBorder).accessibilityIdentifier("connectionDisplayName")
                Text("Название отображается в дереве. Нажми на логотип, чтобы заменить его.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private func chooseLogo() {
        let panel = NSOpenPanel(); panel.title = "Логотип подключения"
        panel.allowedContentTypes = [.png, .jpeg, .webP]
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { appearance.logo = try ConnectionLogo.load(url); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct ConnectionAppearanceView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    let entry: SSHAlias
    @State private var appearance = ConnectionAppearance()
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Название и логотип").font(.title2).bold()
            Text(entry.secondaryTitle).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            ConnectionAppearanceFields(appearance: $appearance, fallback: entry.name)
            if let validation = appearance.validation { Text(validation).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { store.setAppearance(appearance, for: entry); dismiss() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(appearance.validation != nil)
            }
        }.padding(24).frame(width: 490).onAppear { appearance = store.appearance(entry) }
    }
}
