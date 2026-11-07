import SwiftUI
import AppKit

struct MCPSettingsView: View {
    @ObservedObject var controller: MCPController
    @State private var port = ""
    @State private var revealed = false
    @State private var copied = false
    private func change(_ update: (inout MCPConfiguration) -> Void) { var value = controller.configuration; update(&value); controller.save(value) }
    private func permission(_ key: WritableKeyPath<MCPPermissions, Bool>) -> Binding<Bool> {
        Binding(get: { controller.configuration.permissions[keyPath: key] }, set: { enabled in change { $0.permissions[keyPath: key] = enabled } })
    }
    var body: some View {
        Section {
            Toggle("Разрешить подключение ИИ-агентов по MCP", isOn: Binding(get: { controller.configuration.enabled }, set: { enabled in change { $0.enabled = enabled } }))
            Label(controller.listening ? "Сервер работает" : "Сервер остановлен", systemImage: controller.listening ? "checkmark.circle.fill" : "pause.circle")
                .foregroundStyle(controller.listening ? .green : .secondary)
            Text("MCP доступен только на этом Mac, пока база разблокирована. Агент получает записи, документацию и инвентаризацию текущего профиля. Пароли, секреты MFA и приватные ключи не выдаются.")
                .font(.caption).foregroundStyle(.secondary)
        }
        Section("Подключение агента") {
            LabeledContent("Адрес") { Text(controller.endpoint).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            HStack {
                TextField("Локальный порт", text: $port).textFieldStyle(.roundedBorder)
                Button("Применить") { if let number = Int(port) { change { $0.port = number } } else { controller.error = "Укажи порт от 1024 до 65535." } }
            }
            if !controller.configuration.token.isEmpty {
                LabeledContent("Ключ доступа") {
                    HStack {
                        if revealed { Text(controller.configuration.token).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                        else { Text("••••••••••••••••").foregroundStyle(.secondary) }
                        Button { revealed.toggle() } label: { Image(systemName: revealed ? "eye.slash" : "eye") }.help(revealed ? "Скрыть ключ" : "Показать ключ")
                    }
                }
                HStack {
                    Button(copied ? "Конфигурация скопирована" : "Копировать конфигурацию MCP", systemImage: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.clientConfiguration, forType: .string); copied = true
                    }
                    Button("Сменить ключ") { controller.rotateToken(); revealed = false; copied = false }
                }
                Text("Конфигурация содержит ключ доступа к материалам базы. Вставь её в MCP-клиент, которому доверяешь. Смена ключа отключит прежние подключения и отменит запросы.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.onAppear { port = String(controller.configuration.port) }
        Section("Разрешения") {
            Toggle("Создание записей", isOn: permission(\.createRecords))
            Toggle("Изменение документации", isOn: permission(\.writeDocumentation))
            Toggle("Изменение инвентаризации", isOn: permission(\.writeInventory))
            Toggle("SSH-команды и сбор инвентаризации", isOn: permission(\.executeSSH))
            Text("Каждое изменение и каждый запуск дополнительно подтверждаются в окне SSH Hub. Запрос без подтверждения истекает через 2 минуты. При смене профиля или блокировке базы запросы и результаты удаляются.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if !controller.jobs.isEmpty {
            Section("Запросы агента") {
                ForEach(controller.jobs.reversed()) { job in MCPJobRow(controller: controller, job: job) }
            }
        }
        if let error = controller.error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
    }
}

private struct MCPJobRow: View {
    @ObservedObject var controller: MCPController
    @ObservedObject var job: MCPJob
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(.system(.body, design: .monospaced))
                Text(MCPReviewView.statusTitle(job.status)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if job.status == "pending_approval" { Button("Просмотреть…") { controller.review(job.id) } }
            if job.active { Button("Остановить") { controller.cancel(job.id) } }
        }
    }
}

@MainActor final class MCPReviewWindow: NSWindowController, NSWindowDelegate {
    let jobID: UUID
    private weak var model: MCPController?
    init(model: MCPController, job: MCPJob) {
        self.model = model; jobID = job.id
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Запрос MCP · SSH Hub"; window.isReleasedWhenClosed = false; window.minSize = NSSize(width: 540, height: 380)
        window.contentView = NSHostingView(rootView: MCPReviewView(controller: model, job: job)); window.center()
        super.init(window: window); window.delegate = self
    }
    required init?(coder: NSCoder) { nil }
    func windowWillClose(_ notification: Notification) {
        // Defer queue advancement until AppKit has finished closing this window.
        let model = model, id = jobID
        DispatchQueue.main.async { model?.cancel(id, status: "rejected") }
    }
}

struct MCPReviewView: View {
    @ObservedObject var controller: MCPController
    @ObservedObject var job: MCPJob
    static func statusTitle(_ status: String) -> String {
        switch status { case "pending_approval": return "Ожидает подтверждения"; case "running": return "Выполняется"; case "completed": return "Завершён"; case "failed": return "Ошибка"; case "expired": return "Истёк срок подтверждения"; case "rejected": return "Отклонён"; default: return "Отменён" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Запрос ИИ-агента", systemImage: "puzzlepiece.extension").font(.title2.bold())
            Text("Проверь назначение и точное содержимое запроса перед выполнением.").foregroundStyle(.secondary)
            ScrollView {
                Text(job.preview).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }.background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            HStack {
                Text(Self.statusTitle(job.status)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Отклонить") { controller.cancel(job.id, status: "rejected") }.keyboardShortcut(.cancelAction)
                Button("Разрешить") { controller.approve(job.id) }.buttonStyle(.borderedProminent)
            }.disabled(job.status != "pending_approval")
        }.padding(24).frame(minWidth: 500, minHeight: 330).background(Color(nsColor: .windowBackgroundColor))
    }
}
