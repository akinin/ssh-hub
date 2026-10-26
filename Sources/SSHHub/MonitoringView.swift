import SwiftUI
import AppKit
import Darwin

struct MonitoringDashboardView: View {
    @ObservedObject var model: MonitoringModel
    var entries: [SSHAlias] = []
    var currentEntries: (() -> [SSHAlias])? = nil
    @State private var configuring = false
    @State private var query = ""
    @State private var fileError: String?
    @State private var savedCollector: URL?
    @State private var installing = false
    @Environment(\.dismiss) private var dismiss
    private var targets: [MonitoringTarget] { (model.snapshot?.targets ?? []).filter { query.isEmpty || ($0.name + " " + $0.id + " " + $0.kind.title).localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack { Label("Мониторинг", systemImage: "waveform.path.ecg").font(.headline); Spacer(); actions }
                VStack(alignment: .leading, spacing: 8) { Label("Мониторинг", systemImage: "waveform.path.ecg").font(.headline); actions }
            }.padding(12)
            Divider()
            if !model.loadSucceeded {
                ContentUnavailableView { Label("Настройки недоступны", systemImage: "exclamationmark.triangle") } description: { Text(model.error ?? "") } actions: { Button("Прочитать повторно") { model.reload() } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let snapshot = model.snapshot {
                summary(snapshot)
                TextField("Найти цель по имени или типу", text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 12).padding(.bottom, 8)
                GeometryReader { size in
                    if size.size.width >= 760 {
                        HSplitView { targetList; history.frame(minWidth: 300, idealWidth: 400) }
                    } else {
                        VStack(spacing: 0) { targetList.frame(minHeight: 100, maxHeight: size.size.height * 0.5); Divider(); history }
                    }
                }
            } else {
                ContentUnavailableView { Label("Серверный мониторинг", systemImage: "server.rack") } description: {
                    Text("Размести коллектор на постоянно включённом сервере. Он будет собирать доступность, задержку и историю TCP, HTTP и WAN даже когда этот Mac выключен. Затем укажи его адрес и API-токен.")
                } actions: { Button("Настроить коллектор") { configuring = true }.disabled(model.busy) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if let error = model.error { Text(error).foregroundStyle(.orange) }
                if let error = fileError { Text(error).foregroundStyle(.orange) }
                if let savedCollector { Text("Коллектор сохранён: " + savedCollector.path).textSelection(.enabled) }
                Text(model.polling ? "Обновление с сервера каждые \(model.settings.pollSeconds) с. Закрытие окна останавливает обновление на Mac." : "Обновление на Mac остановлено. Серверный сбор работает независимо от приложения.")
            }.font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(10)
        }.sheet(isPresented: $configuring) { MonitoringConfigurationView(model: model) }
        .sheet(isPresented: $installing) { MonitoringInstallationView(monitoring: model, entries: entries, currentEntries: currentEntries ?? { entries }) }
        .onAppear { model.entries = entries }
        .onDisappear { model.stop() }
        .frame(width: 920, height: 680, alignment: .top)
    }
    private var actions: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            Button("Обновить", systemImage: "arrow.clockwise") { model.refresh() }.disabled(model.busy || !model.hasToken || !model.loadSucceeded)
            if model.polling { Button("Остановить", systemImage: "stop.fill") { model.stop() } }
            else { Button("Подключиться", systemImage: "play.fill") { model.startPolling() }.disabled(model.busy || !model.hasToken || !model.loadSucceeded) }
            Button { configuring = true } label: { Image(systemName: "gearshape") }.help("Настройки коллектора").accessibilityLabel("Настройки коллектора").disabled(model.busy || !model.loadSucceeded)
            Button("Сохранить коллектор…", systemImage: "square.and.arrow.down") { saveCollector() }
            Button("Установить на сервер…", systemImage: "arrow.up.doc") { installing = true }.disabled(model.busy || model.installation.busy || !model.loadSucceeded)
            Button("Готово") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
        }.controlSize(.small)
    }
    private func saveCollector() {
        let panel = NSOpenPanel(); panel.title = "Папка для серверного коллектора"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let parent = panel.url else { return }
        let destination = parent.appendingPathComponent("SSH-Hub-Monitor-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        let names = ["collector.py", "config.example.json", "ssh-hub-monitor.service", "Caddyfile.example", "README.md", "install.py"]
        var created = false
        do {
            guard let resources = Bundle.main.resourceURL?.appendingPathComponent("MonitoringCollector", isDirectory: true), names.allSatisfy({ FileManager.default.fileExists(atPath: resources.appendingPathComponent($0).path) }) else { throw MonitoringError.collectorMissing }
            guard mkdir(destination.path, 0o700) == 0 else { throw MonitoringError.export }; created = true
            for name in names { let target = destination.appendingPathComponent(name); try FileManager.default.copyItem(at: resources.appendingPathComponent(name), to: target); try FileManager.default.setAttributes([.posixPermissions: name == "collector.py" ? 0o700 : 0o600], ofItemAtPath: target.path) }
            savedCollector = destination; fileError = nil; NSWorkspace.shared.activateFileViewerSelecting([destination])
        } catch { if created { try? FileManager.default.removeItem(at: destination) }; fileError = error.localizedDescription }
    }
    private func summary(_ snapshot: MonitoringSnapshot) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let fresh = snapshot.targets.filter { !$0.stale(at: timeline.date) }
            HStack(spacing: 16) {
                Label("Доступны: \(fresh.filter { $0.latest?.reachable == true }.count)", systemImage: "checkmark.circle").foregroundStyle(.green)
                Label("Недоступны: \(fresh.filter { $0.latest?.reachable == false }.count)", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                Text("Без свежих данных: \(snapshot.targets.count - fresh.count)").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.font(.caption).padding(12)
        }
        .overlay(alignment: .bottomLeading) { if !snapshot.healthy { Text("Коллектор сообщает об ошибке сбора").font(.caption2).foregroundStyle(.orange).padding(.horizontal, 12) } }
    }
    private var targetList: some View {
        List(targets, selection: Binding(get: { model.selectedTarget }, set: { if let target = $0 { model.loadHistory(target) } else { model.selectedTarget = nil } })) { target in
            TimelineView(.periodic(from: .now, by: 30)) { timeline in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: target.kind.symbol).frame(width: 22).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(target.name).fontWeight(.medium).lineLimit(1)
                        HStack { Text(target.kind.title); if let sample = target.latest { Text(sample.date.formatted(date: .omitted, time: .standard)); Text(String(format: "%.1f мс", sample.latencyMS)) } }.font(.caption).foregroundStyle(.secondary)
                        if let percent = target.availability24h { Text(String(format: "Доступность 24 ч: %.2f%% · %d проверок", percent, target.samples24h)).font(.caption2).foregroundStyle(.secondary) }
                    }
                    Spacer(minLength: 6)
                    Circle().fill(target.stale(at: timeline.date) ? Color.secondary : (target.latest?.reachable == true ? .green : .orange)).frame(width: 8, height: 8).help(target.stale(at: timeline.date) ? "Нет свежего измерения" : (target.latest?.explanation ?? "Не проверено"))
                }.padding(.vertical, 5)
            }.tag(target.id)
        }.overlay { if targets.isEmpty { ContentUnavailableView.search(text: query) } }
    }
    private var history: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let target = model.snapshot?.targets.first(where: { $0.id == model.selectedTarget }) {
                HStack { Label(target.name, systemImage: "clock.arrow.circlepath").font(.headline).lineLimit(1); Spacer() }
                Text("Последние \(model.history.count) измерений · источник: серверный коллектор").font(.caption).foregroundStyle(.secondary)
                if model.history.count > 1 {
                    MonitoringLatencyChart(samples: model.history).frame(height: 90)
                    Text("Задержка успешных проверок, мс").font(.caption2).foregroundStyle(.secondary)
                }
                List(model.history) { sample in
                    HStack(spacing: 8) {
                        Image(systemName: sample.reachable ? "checkmark.circle.fill" : "exclamationmark.circle.fill").foregroundStyle(sample.reachable ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) { Text(sample.date.formatted(date: .abbreviated, time: .standard)); Text(sample.explanation).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(String(format: "%.1f мс", sample.latencyMS)).font(.caption).monospacedDigit()
                    }
                }.listStyle(.plain)
                Text("Показано до 250 измерений. Сервер хранит до \(model.snapshot?.retentionDays ?? 30) дней, максимум 500 000 измерений на коллектор.").font(.caption2).foregroundStyle(.secondary)
            } else {
                ContentUnavailableView("Выбери цель", systemImage: "chart.xyaxis.line", description: Text("Откроются история доступности и задержки, измеренные на сервере."))
            }
        }.padding(12)
    }
}

private struct MonitoringLatencyChart: View {
    let samples: [MonitoringSample]
    var body: some View {
        GeometryReader { geometry in
            let ordered = samples.sorted { $0.checkedAt < $1.checkedAt }
            let first = ordered.first?.checkedAt ?? 0, last = ordered.last?.checkedAt ?? 1
            let maxLatency = max(1, ordered.filter(\.reachable).map(\.latencyMS).max() ?? 1)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                Path { path in
                    var connected = false
                    for sample in ordered {
                        guard sample.reachable else { connected = false; continue }
                        let point = CGPoint(x: (sample.checkedAt - first) / max(1, last - first) * (geometry.size.width - 16) + 8, y: geometry.size.height - 8 - sample.latencyMS / maxLatency * (geometry.size.height - 20))
                        if connected { path.addLine(to: point) } else { path.move(to: point) }; connected = true
                    }
                }.stroke(.blue, lineWidth: 1.5)
                Text(String(format: "%.1f", maxLatency)).font(.caption2).foregroundStyle(.secondary).padding(4)
            }
        }.accessibilityLabel("График задержки успешных проверок")
    }
}

private struct MonitoringConfigurationView: View {
    @ObservedObject var model: MonitoringModel
    @Environment(\.dismiss) private var dismiss
    @State private var endpoint = ""
    @State private var token = ""
    @State private var interval = 60
    @State private var notifications = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Серверный мониторинг", systemImage: "server.rack").font(.title2).bold()
            Text("Запусти коллектор на постоянно работающем сервере, добавь цели TCP/HTTP/WAN и настрой доверенный HTTPS-адрес. Этот Mac получает только результаты проверок.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Адрес коллектора", text: $endpoint, prompt: Text("https://monitor.example.com"))
                SecureField("API-токен", text: $token, prompt: Text(model.hasToken ? "Сохранён · оставь пустым" : "Токен коллектора"))
                Picker("Обновлять на Mac", selection: $interval) { ForEach([10, 30, 60, 300, 900, 3600], id: \.self) { Text("Каждые \($0) с").tag($0) } }
                Toggle("Уведомлять об изменении доступности и WAN", isOn: $notifications)
            }.textFieldStyle(.roundedBorder)
            Text("Токен хранится в Связке ключей отдельно для профиля, SSH-конфига и адреса коллектора. Настройка не запускает сбор на Mac; нажми «Подключиться» после сохранения. Уведомления приходят при открытом приложении и включённом обновлении.").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("Инструкция и серверный коллектор", destination: URL(string: "https://github.com/akinin/ssh-hub/tree/main/MonitoringCollector")!)
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Удалить сохранённый токен") { model.forgetToken() }.disabled(!model.hasToken || model.busy)
                Spacer()
                Button("Отмена") { token = ""; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Сохранить") { if model.configure(endpoint: endpoint, token: token.isEmpty ? nil : token, pollSeconds: interval, notifyChanges: notifications) { token = ""; dismiss() } }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }
        }.padding(22).frame(minWidth: 440, idealWidth: 580, maxWidth: 680)
        .onAppear { endpoint = model.settings.endpoint; interval = model.settings.pollSeconds; notifications = model.settings.notifyChanges }
        .onDisappear { token = "" }
    }
}
