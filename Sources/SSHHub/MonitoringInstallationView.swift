import SwiftUI

struct MonitoringInstallationView: View {
    @ObservedObject var monitoring: MonitoringModel
    @ObservedObject var installer: MonitoringInstallationModel
    let entries: [SSHAlias]
    let currentEntries: () -> [SSHAlias]
    @Environment(\.dismiss) private var dismiss
    @State private var selected = ""
    @State private var remotePort = 8787
    @State private var targets = [MonitoringInstallTarget(name: "Сервер · SSH", host: "127.0.0.1", port: 22)]
    @State private var plan: MonitoringInstallationPlan?
    @State private var error: String?
    init(monitoring: MonitoringModel, entries: [SSHAlias], currentEntries: @escaping () -> [SSHAlias]) {
        self.monitoring = monitoring; installer = monitoring.installation; self.entries = entries; self.currentEntries = currentEntries
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("Установить коллектор на сервер", systemImage: "server.rack").font(.title2).bold(); Spacer(); Button("Закрыть") { installer.stop(); dismiss() }.keyboardShortcut(.cancelAction) }
            if let plan {
                Text("Проверь сервер, новые пути, цели и точную команду. Мастер создаёт отдельную службу и не заменяет существующую установку.").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(plan.review).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                HStack {
                    Button("Назад") { self.plan = nil }.disabled(installer.busy)
                    Spacer()
                    if installer.busy { ProgressView().controlSize(.small); Button("Остановить установку") { installer.stop() } }
                    else {
                        if monitoring.settings.instanceID == plan.id, monitoring.hasToken { Button("Проверить подключение") { monitoring.startPolling(); dismiss() } }
                        Button("Установить и подключить") { installer.run(plan, current: currentEntries(), config: monitoring.configURL, monitoring: monitoring) }.buttonStyle(.borderedProminent).disabled(installer.installedID == plan.id)
                    }
                }
            } else {
                Text("Нужны сохранённая SSH-запись с пользователем root, Linux, Python 3.9+ и systemd 247+. Служба работает без постоянных root-прав через DynamicUser. Пакеты и правила firewall не меняются.").font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Сервер SSH", selection: $selected) {
                    Text("Выбери запись…").tag("")
                    ForEach(entries.filter { $0.canSSH && !$0.isQuickConnection }) { entry in Text(entry.name + " · " + entry.user + "@" + entry.host).tag(entry.favoriteID) }
                }
                HStack { Text("Порт коллектора на сервере"); TextField("8787", value: $remotePort, format: .number).frame(width: 90); Text("Только 127.0.0.1, доступ через SSH-туннель").font(.caption).foregroundStyle(.secondary); Spacer() }
                Text("Цели проверяются с сервера коллектора").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach($targets) { $target in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    TextField("Имя цели", text: $target.name)
                                    Picker("Тип", selection: $target.kind) { Text("TCP").tag(MonitoringKind.tcp); Text("HTTP").tag(MonitoringKind.http); Text("WAN").tag(MonitoringKind.wan) }.frame(width: 140)
                                    Button { targets.removeAll { $0.id == target.id } } label: { Image(systemName: "trash") }.disabled(targets.count == 1).help("Убрать цель")
                                }
                                if target.kind == .http { TextField("https://example.com/health", text: $target.url) }
                                else { HStack { TextField("Адрес или IP", text: $target.host); TextField("Порт", value: $target.port, format: .number).frame(width: 90) } }
                                HStack { Picker("Интервал", selection: $target.intervalSeconds) { ForEach([10, 30, 60, 300, 900, 3600], id: \.self) { Text("\($0) с").tag($0) } }.frame(width: 180); if let error = target.validation { Text(error).font(.caption).foregroundStyle(.orange) }; Spacer() }
                            }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                HStack { Button("Добавить цель", systemImage: "plus") { targets.append(MonitoringInstallTarget()) }.disabled(targets.count >= 64); Spacer(); Text("WAN — метка цели, маршрутизация сервера не меняется.").font(.caption).foregroundStyle(.secondary) }
                HStack { Spacer(); Button("Просмотреть план установки") { makePlan() }.buttonStyle(.borderedProminent).disabled(selected.isEmpty || targets.contains(where: { $0.validation != nil }) || !(1024...65535).contains(remotePort)) }
            }
            if !installer.status.isEmpty { Text(installer.status).font(.caption).foregroundStyle(.secondary) }
            if let error = error ?? installer.error { Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
        }.textFieldStyle(.roundedBorder).padding(22).frame(width: 820, height: 650).interactiveDismissDisabled(installer.busy)
        .onDisappear { installer.stop() }
    }
    private func makePlan() {
        do {
            guard let entry = currentEntries().first(where: { $0.favoriteID == selected }) else { throw ConfigError.message("SSH-запись больше недоступна в текущем профиле.") }
            monitoring.stop(); plan = try MonitoringInstallationPlan(entry: entry, remotePort: remotePort, targets: targets); error = nil
        } catch { self.error = error.localizedDescription }
    }
}
