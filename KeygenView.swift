import SwiftUI
import AppKit

struct GenerateKeyView: View {
    let directory: URL
    var onUse: ((URL) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft = KeyDraft()
    @State private var result: GeneratedKey?
    @State private var generating = false
    @State private var error: String?
    @State private var copied = false
    private var validation: String? { draft.validation(in: directory) }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                Image(systemName: result == nil ? "key.fill" : "checkmark.shield.fill")
                    .font(.system(size: 29)).foregroundStyle(result == nil ? .blue : .green)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result == nil ? "Новый SSH-ключ" : "SSH-ключ готов").font(.title2).bold()
                    Text(result == nil ? "Ed25519 · создаётся локально на Mac" : "Скопируй команду и выполни на нужном сервере")
                        .foregroundStyle(.secondary)
                }
            }
            if let result {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Команда установки публичного ключа").font(.headline)
                    Text(result.installCommand).font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                    Button(copied ? "Команда скопирована" : "Копировать команду установки", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.installCommand, forType: .string)
                        copied = true
                    }.buttonStyle(.borderedProminent).controlSize(.large)
                    Text("Выполни от имени пользователя, под которым будешь подключаться. Команда добавит публичный ключ в ~/.ssh/authorized_keys и выставит права доступа.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Приватный ключ остаётся на Mac").font(.headline)
                    Text(result.privateURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text(result.fingerprint).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                }
                HStack {
                    Button("Показать файлы", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.publicURL])
                    }
                    Spacer()
                    if let onUse {
                        Button("Использовать в алиасе") { onUse(result.privateURL); dismiss() }
                            .keyboardShortcut(.defaultAction)
                    } else {
                        Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                Form {
                    TextField("Имя файла", text: $draft.filename).accessibilityIdentifier("keyFilename")
                    TextField("Комментарий", text: $draft.comment).accessibilityIdentifier("keyComment")
                    PasswordEntryView(prompt: "Пароль ключа (необязательно)", text: $draft.passphrase, onGenerated: { draft.confirmation = $0 })
                        .accessibilityIdentifier("keyPassphrase")
                    PasswordEntryView(prompt: "Повтори пароль", text: $draft.confirmation, showsGenerator: false)
                        .accessibilityIdentifier("keyConfirmation")
                }.formStyle(.grouped).frame(height: 300).disabled(generating)
                Text(directory.appendingPathComponent(draft.filename).path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                Text("При пустом пароле ключ будет без парольной защиты. Существующие файлы не перезаписываются.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let message = error ?? validation {
                    Label(message, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    if generating { ProgressView().controlSize(.small); Text("Создание ключа…").foregroundStyle(.secondary) }
                    Spacer()
                    Button("Отмена", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction).disabled(generating)
                    Button("Создать ключ") { generate() }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction).disabled(generating || validation != nil)
                }
            }
        }.padding(26).frame(width: 590).interactiveDismissDisabled(generating).dismissOnOutsideClick(enabled: !generating)
    }
    func generate() {
        generating = true
        error = nil
        let keyDraft = draft
        let keyDirectory = directory
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/SSHAskpass")
        Task {
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    try KeyGenerator.generate(keyDraft, directory: keyDirectory, helper: helper)
                }.value
                draft.passphrase = ""
                draft.confirmation = ""
                result = key
            } catch { self.error = error.localizedDescription }
            generating = false
        }
    }
}
