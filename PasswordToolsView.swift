import SwiftUI
import AppKit
import Security

// All generation and assessment stay on this Mac; no password is sent to a service.
enum PasswordTools {
    static let groups = [Array("abcdefghijkmnopqrstuvwxyz"), Array("ABCDEFGHJKLMNPQRSTUVWXYZ"), Array("23456789"), Array("!@#$%&*+-_=?")]
    static func generate(length: Int = 24, selected: Set<Int> = [0,1,2,3]) throws -> String {
        let chosen = selected.sorted().filter { groups.indices.contains($0) }.map { groups[$0] }
        guard (8...128).contains(length), !chosen.isEmpty else { throw NSError(domain: "PasswordGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Выбери символы и длину от 8 до 128."]) }
        func index(_ count: Int) throws -> Int {
            // Rejection sampling avoids modulo bias.
            var byte: UInt8 = 0
            repeat { guard SecRandomCopyBytes(kSecRandomDefault, 1, &byte) == errSecSuccess else { throw NSError(domain: "PasswordGenerator", code: 2, userInfo: [NSLocalizedDescriptionKey: "Генератор случайных чисел недоступен."]) } } while Int(byte) >= 256 - 256 % count
            return Int(byte) % count
        }
        let pool = chosen.flatMap { $0 }
        var result = try chosen.map { $0[try index($0.count)] }
        while result.count < length { result.append(pool[try index(pool.count)]) }
        for offset in stride(from: result.count - 1, through: 1, by: -1) { result.swapAt(offset, try index(offset + 1)) }
        return String(result)
    }
    struct Assessment: Equatable {
        let level: Int
        let detail: String
        var title: String { ["Очень слабый", "Слабый", "Средний", "Надёжный", "Очень надёжный"][level] }
    }
    static func assess(_ password: String) -> Assessment {
        let chars = Array(password.prefix(16384)), lower = password.lowercased()
        let common = ["password", "пароль", "qwerty", "admin", "letmein", "welcome", "123456", "йцукен"]
        if chars.count < 8 || common.contains(where: lower.contains) || Set(chars).count < 4 {
            return Assessment(level: 0, detail: "Короткий, повторяющийся или распространённый пароль.")
        }
        let sequences = ["abcdefghijklmnopqrstuvwxyz", "0123456789", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let sequential = sequences.contains { sequence in
            let sequence = Array(sequence)
            return (0...max(0, sequence.count - 6)).contains { start in
                let fragment = String(sequence[start..<min(sequence.count, start + 6)])
                return lower.contains(fragment) || lower.contains(String(fragment.reversed()))
            }
        }
        let repeated = (1...min(8, chars.count / 2)).contains { size in chars.enumerated().allSatisfy { $0.element == chars[$0.offset % size] } }
        if sequential || repeated { return Assessment(level: 1, detail: "Есть последовательности или повторяющиеся фрагменты.") }
        let classes = [CharacterSet.lowercaseLetters, .uppercaseLetters, .decimalDigits, .symbols.union(.punctuationCharacters)].filter { set in password.unicodeScalars.contains(where: set.contains) }.count
        let level = chars.count >= 24 && Set(chars).count >= 10 ? 4 : chars.count >= 16 && classes >= 3 ? 3 : chars.count >= 12 ? 2 : 1
        return Assessment(level: level, detail: level < 3 ? "Увеличь длину; избегай имён, дат и повторного использования." : "Локальная оценка. Уникальность и наличие в утечках не проверяются.")
    }
    static func age(_ date: Date?, now: Date = Date()) -> String {
        guard let date, date <= now else { return "Дата смены неизвестна" }
        let days = max(0, Calendar.current.dateComponents([.day], from: date, to: now).day ?? 0)
        return "Сохранён в SSH Hub: " + date.formatted(date: .abbreviated, time: .omitted) + " · \(days) дн. назад"
    }
}

struct PasswordStrengthView: View {
    let assessment: PasswordTools.Assessment
    private var color: Color { assessment.level < 2 ? .red : assessment.level == 2 ? .orange : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) { ForEach(0..<5) { index in Capsule().fill(index <= assessment.level ? color : Color.secondary.opacity(0.2)).frame(width: 22, height: 3) }; Text(assessment.title).foregroundStyle(color) }
            Text(assessment.detail).foregroundStyle(.secondary)
        }.font(.caption)
    }
}

// A Form can give SwiftUI fields trailing alignment. Keep the native password
// editor explicitly left aligned, with a fixed control height and no Form label.
struct LeadingSecureField: NSViewRepresentable {
    let prompt: String
    @Binding var text: String
    @Environment(\.isEnabled) private var isEnabled
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.delegate = context.coordinator
        field.alignment = .left; field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.isBezeled = true; field.bezelStyle = .roundedBezel
        field.cell?.usesSingleLineMode = true; field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func updateNSView(_ field: NSSecureTextField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = prompt; field.setAccessibilityLabel(prompt)
        field.alignment = .left; field.isEnabled = isEnabled
        if field.stringValue != text { field.stringValue = text }
        (field.currentEditor() as? NSTextView)?.baseWritingDirection = .leftToRight
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSecureTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}

struct PasswordEntryView: View {
    let prompt: String
    @Binding var text: String
    var changedAt: Date? = nil
    var savedPassword: (() throws -> String?)? = nil
    var onGenerated: ((String) -> Void)? = nil
    var showsGenerator = true
    @State private var generator = false
    @State private var assessment: PasswordTools.Assessment?
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .center, spacing: 8) {
                LeadingSecureField(prompt: prompt, text: $text).frame(height: 26)
                if showsGenerator {
                    Button { generator = true } label: { Image(systemName: "dice").frame(width: 20, height: 20) }
                        .buttonStyle(.bordered).controlSize(.regular).frame(width: 36, height: 26)
                        .help("Генератор паролей").accessibilityLabel("Генератор паролей")
                }
            }.frame(height: 28).environment(\.layoutDirection, .leftToRight)
            if !text.isEmpty { PasswordStrengthView(assessment: PasswordTools.assess(text)) }
            else if let assessment { PasswordStrengthView(assessment: assessment) }
            if let savedPassword, text.isEmpty {
                HStack { Text(PasswordTools.age(changedAt)); Button("Проверить надёжность") { do { if let value = try savedPassword() { assessment = PasswordTools.assess(value) } else { error = "Пароль не сохранён" } } catch { self.error = "Не удалось прочитать пароль из Связки ключей." } }.buttonStyle(.link) }.font(.caption).foregroundStyle(.secondary)
                Text("Смена на сервере не отслеживается.").font(.caption2).foregroundStyle(.secondary)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.sheet(isPresented: $generator) { PasswordGeneratorView { value in text = value; onGenerated?(value) } }
            .onChange(of: text) { _, _ in assessment = nil; error = nil }
            .onChange(of: prompt) { _, _ in assessment = nil; error = nil }
            .onChange(of: savedPassword != nil) { _, _ in assessment = nil; error = nil }
    }
}

struct PasswordGeneratorView: View {
    var onUse: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var length = 24
    @State private var selected: Set<Int> = [0,1,2,3]
    @State private var password = ""
    @State private var revealed = false
    @State private var error: String?
    @State private var copied = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Генератор паролей", systemImage: "dice").font(.title2.bold())
            Stepper("Длина: \(length)", value: $length, in: 8...128)
            HStack { ForEach(0..<4) { index in Toggle(["a–z", "A–Z", "2–9", "!@#"][index], isOn: Binding(get: { selected.contains(index) }, set: { if $0 { selected.insert(index) } else { selected.remove(index) } })).toggleStyle(.checkbox) } }
            HStack {
                Group { if revealed { TextField("Пароль", text: $password) } else { SecureField("Пароль", text: $password) } }.textFieldStyle(.roundedBorder)
                Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }.help("Показать / скрыть пароль")
            }
            if !password.isEmpty { PasswordStrengthView(assessment: PasswordTools.assess(password)) }
            Text("Создаётся на Mac. «Использовать» только заполняет поле; пароль на сервере не меняется.").font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Button("Сгенерировать", systemImage: "arrow.clockwise") { generate() }.disabled(selected.isEmpty)
                Button(copied ? "Скопирован" : "Копировать", systemImage: "doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(password, forType: .string); copied = true }.disabled(password.isEmpty)
                Spacer()
                if onUse != nil { Button("Отмена") { dismiss() }.keyboardShortcut(.cancelAction) }
                if let onUse { Button("Использовать") { onUse(password); dismiss() }.buttonStyle(.borderedProminent).disabled(password.isEmpty) }
                else { Button("Закрыть") { dismiss() } }
            }
        }.padding(22).frame(minWidth: 440).onAppear { generate() }.onDisappear { password = "" }
    }
    private func generate() { do { password = try PasswordTools.generate(length: length, selected: selected); error = nil; copied = false } catch { self.error = error.localizedDescription } }
}

struct SSHAuthenticationChecks: View {
    @Binding var selection: SSHAuthentication
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Использовать SSH-ключ", isOn: Binding(get: { selection.usesKey }, set: { selection = .selected(key: $0, password: selection.usesPassword) })).toggleStyle(.checkbox)
            Toggle("Использовать пароль", isOn: Binding(get: { selection.usesPassword }, set: { selection = .selected(key: selection.usesKey, password: $0) })).toggleStyle(.checkbox)
            if selection == .automatic { Text("Без галочек — обычный автоматический выбор OpenSSH.").font(.caption).foregroundStyle(.secondary) }
            if selection == .keyAndPassword { Text("Сначала ключ, затем пароль, если сервер его запросит.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
