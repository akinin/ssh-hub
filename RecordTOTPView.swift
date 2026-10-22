import SwiftUI
import AppKit

@MainActor enum RecordTOTPClipboard {
    @discardableResult static func copy(_ token: TOTPToken) -> Date? {
        let now = Date(), board = NSPasteboard.general
        board.clearContents()
        guard board.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")),
              board.setString(token.code(at: now), forType: .string) else { board.clearContents(); return nil }
        let stamp = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + token.remaining(at: now)) { if board.changeCount == stamp { board.clearContents() } }
        return now.addingTimeInterval(token.remaining(at: now))
    }
}
extension AliasStore {
    @discardableResult func copyTOTP(_ entry: SSHAlias) -> Date? {
        guard !AppAccess.shared.locked, !endingWorkspace, profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }) else { return nil }
        let config = config.url, profile = profiles.active, revision = AppAccess.shared.authorizationRevision
        do {
            let token = try RecordTOTPStore.read(RecordTOTPStore.account(config: config, record: entry.favoriteID))
            guard !AppAccess.shared.locked, !endingWorkspace, self.config.url == config, profiles.active == profile, AppAccess.shared.authorizationRevision == revision, profileEntries.contains(where: { $0.favoriteID == entry.favoriteID }) else { return nil }
            guard let token else { notice = "MFA для записи не настроен"; return nil }
            guard let expiry = RecordTOTPClipboard.copy(token) else { error = "Не удалось скопировать MFA-код"; return nil }
            notice = "MFA-код скопирован"
            return expiry
        } catch { self.error = error.localizedDescription; return nil }
    }
}
struct RecordTOTPBadge: View {
    let entry: SSHAlias
    @EnvironmentObject private var store: AliasStore
    @ObservedObject private var access = AppAccess.shared
    @State private var token: TOTPToken?
    @State private var loadedScope = ""
    @State private var error: String?
    @State private var copiedUntil: Date?
    private var scope: String { RecordTOTPStore.account(config: store.config.url, record: entry.favoriteID) + store.profiles.active.uuidString + access.authorizationRevision.uuidString + String(access.locked) }
    private var allowed: Bool { !access.locked && !store.endingWorkspace && store.profileEntries.contains { $0.favoriteID == entry.favoriteID } }
    private func load(interactive: Bool = false) {
        token = nil; error = nil; copiedUntil = nil; loadedScope = scope
        guard allowed else { return }
        let expected = scope
        do {
            let value = try RecordTOTPStore.read(RecordTOTPStore.account(config: store.config.url, record: entry.favoriteID), allowInteraction: interactive)
            guard expected == scope, allowed else { return }
            token = value
        } catch { if expected == scope { self.error = error.localizedDescription } }
    }
    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
            if allowed, loadedScope == scope {
                if let token {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let copied = copiedUntil.map { context.date < $0 } ?? false
                        Button {
                            copiedUntil = nil
                            if let expiry = store.copyTOTP(entry) { copiedUntil = min(Date().addingTimeInterval(2), expiry) }
                        } label: {
                            Label(copied ? "Скопировано" : String(format: "%02d", Int(ceil(token.remaining(at: context.date)))) + " с · " + token.code(at: context.date), systemImage: copied ? "checkmark" : "lock.rotation")
                                .font(.caption.weight(.medium)).monospacedDigit().padding(.horizontal, 8).padding(.vertical, 4)
                        }.buttonStyle(.plain).background(.quaternary, in: Capsule()).fixedSize()
                            .help("Копировать MFA-код · обновится через \(Int(ceil(token.remaining(at: context.date)))) с")
                            .accessibilityIdentifier("recordTOTPBadge")
                    }
                } else if error != nil {
                    Button("MFA", systemImage: "lock.rotation") { load(interactive: true) }.buttonStyle(.bordered).controlSize(.small).help(error ?? "")
                }
            }
        }.onAppear { load() }.onChange(of: scope) { _, _ in load() }.onDisappear { token = nil; copiedUntil = nil; loadedScope = "" }
            .onReceive(NotificationCenter.default.publisher(for: RecordTOTPStore.changed)) { _ in load() }
            .onReceive(access.$locked) { if $0 { token = nil; copiedUntil = nil; loadedScope = "" } }
    }
}

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
                            RecordTOTPClipboard.copy(token)
                        }
                    }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onAppear { present = RecordTOTPStore.has(account) }.onDisappear { token = nil }
            .onChange(of: entry.favoriteID) { _, _ in token = nil; present = RecordTOTPStore.has(account) }
            .onChange(of: config) { _, _ in token = nil; present = RecordTOTPStore.has(account) }
            .onChange(of: store.profiles.active) { _, _ in token = nil }
            .onReceive(NotificationCenter.default.publisher(for: RecordTOTPStore.changed)) { _ in token = nil; present = RecordTOTPStore.has(account) }
            .onReceive(AppAccess.shared.$locked) { if $0 { token = nil } }
    }
}
