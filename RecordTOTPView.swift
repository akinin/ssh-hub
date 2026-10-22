import SwiftUI
import AppKit

@MainActor final class RecordTOTPDraft: ObservableObject {
    @Published var input = ""
    @Published var algorithm = TOTPToken.Algorithm.SHA1
    @Published var digits = 6
    @Published var period = 30
    @Published var remove = false
    var validation: String? { guard !input.isEmpty, !remove else { return nil }; do { _ = try token(); return nil } catch { return error.localizedDescription } }
    func token() throws -> TOTPToken { try TOTPToken.parse(input, algorithm: algorithm, digits: digits, period: period) }
    func prepare(target: SSHAlias, original: SSHAlias?, config: URL) throws -> (() throws -> Void)? {
        guard !AppAccess.shared.locked else { throw ConfigError.message("Разблокируй приложение для изменения MFA.") }
        let account = RecordTOTPStore.account(config: config, record: target.favoriteID)
        var value: TOTPToken?
        if remove { value = nil }
        else if !input.isEmpty { value = try token() }
        else if let original, original.favoriteID != target.favoriteID {
            value = try RecordTOTPStore.read(RecordTOTPStore.account(config: config, record: original.favoriteID))
            guard value != nil else { return nil }
            guard !RecordTOTPStore.has(account) else { throw ConfigError.message("У новой записи уже есть TOTP. Изменение отменено.") }
        } else { return nil }
        var changes: [(String, TOTPToken?, TOTPToken?)] = [(account, try RecordTOTPStore.read(account), value)]
        if remove, let original {
            let old = RecordTOTPStore.account(config: config, record: original.favoriteID)
            if old != account { changes.append((old, try RecordTOTPStore.read(old), nil)) }
        }
        var applied: [(String, TOTPToken?, TOTPToken?)] = []
        do { for change in changes { try RecordTOTPStore.write(change.2, account: change.0); applied.append(change) } }
        catch { for change in applied.reversed() { try? RecordTOTPStore.write(change.1, account: change.0) }; throw error }
        return {
            for change in changes { guard try RecordTOTPStore.read(change.0) == change.2 else { throw ConfigError.message("TOTP изменился после сохранения; автоматический откат отменён.") } }
            for change in changes.reversed() { try RecordTOTPStore.write(change.1, account: change.0) }
        }
    }
    func clear() { input = "" }
}
struct RecordTOTPFields: View {
    @ObservedObject var draft: RecordTOTPDraft
    var entry: SSHAlias?
    let config: URL
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("MFA · TOTP", systemImage: "lock.rotation").font(.headline)
            if let entry {
                RecordTOTPCode(entry: entry, config: config, showTitle: false)
                Toggle("Удалить сохранённый TOTP при сохранении записи", isOn: $draft.remove)
            }
            Text("Секрет Base32 или ссылка otpauth://totp").font(.callout)
            SecureField("Оставь пустым, чтобы сохранить текущий TOTP", text: $draft.input).textFieldStyle(.roundedBorder).disabled(draft.remove).accessibilityIdentifier("recordTOTPSecret")
            if !draft.input.lowercased().hasPrefix("otpauth:") {
                RecordFieldRow("Алгоритм") { Picker("Алгоритм", selection: $draft.algorithm) { ForEach(TOTPToken.Algorithm.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden() }
                RecordFieldRow("Цифры") { Picker("Цифры", selection: $draft.digits) { Text("6").tag(6); Text("8").tag(8) }.labelsHidden() }
                RecordFieldRow("Период, с") { TextField("30", value: $draft.period, format: .number).textFieldStyle(.roundedBorder).frame(width: 100) }
            }
            if let validation = draft.validation { Text(validation).font(.caption).foregroundStyle(.orange) }
            Text("Применяется кнопкой сохранения записи. Секрет хранится только в Связке ключей macOS; в JSON и резервный архив пока не включается. TOTP не включается на сервере автоматически и не подставляется в форму входа.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
struct RecordTOTPCode: View {
    let entry: SSHAlias
    let config: URL
    var showTitle = true
    @State private var token: TOTPToken?
    @State private var error: String?
    @State private var present = false
    @EnvironmentObject var store: AliasStore
    private var account: String { RecordTOTPStore.account(config: config, record: entry.favoriteID) }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if present || token != nil {
                HStack {
                    Text(showTitle ? "MFA · TOTP" : "TOTP настроен").font(.headline)
                    Spacer()
                    Button(token == nil ? "Показать код" : "Скрыть код") {
                        guard !AppAccess.shared.locked else { return }
                        do { if token == nil { token = try RecordTOTPStore.read(account) } else { token = nil }; error = nil } catch { self.error = error.localizedDescription }
                    }
                }
            }
            if let token {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let code = token.code(at: context.date), remaining = token.period - Int(context.date.timeIntervalSince1970) % token.period
                    HStack(spacing: 16) {
                        Text(code).font(.system(size: 26, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                        Text("\(remaining) с").font(.caption).foregroundStyle(.secondary)
                        Button("Копировать код") {
                            guard !AppAccess.shared.locked else { return }
                            let current = token.code(); NSPasteboard.general.clearContents(); NSPasteboard.general.setString(current, forType: .string)
                            let count = NSPasteboard.general.changeCount
                            DispatchQueue.main.asyncAfter(deadline: .now() + Double(remaining)) { if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() } }
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onAppear { present = RecordTOTPStore.has(account) }.onDisappear { token = nil }
            .onChange(of: entry.favoriteID) { _, _ in token = nil; present = RecordTOTPStore.has(account) }
            .onChange(of: config) { _, _ in token = nil; present = RecordTOTPStore.has(account) }
            .onChange(of: store.profiles.active) { _, _ in token = nil }
            .onReceive(AppAccess.shared.$locked) { if $0 { token = nil } }
    }
}
