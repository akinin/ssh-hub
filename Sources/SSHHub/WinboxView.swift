import SwiftUI

struct WinboxView: View {
    @ObservedObject var model: WinboxModel
    var body: some View {
        GeometryReader { viewport in
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("WinBox · " + model.entry.name, systemImage: "network").font(.headline).lineLimit(1)
                    Spacer()
                    if model.dirty { Button("Сохранить") { model.save() }.disabled(!model.loadSucceeded || model.busy || model.running) }
                }.padding(12)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Нативный WinBox открывается отдельным приложением. Эта вкладка хранит настройки и управляет SSH-туннелем.").foregroundStyle(.secondary)
                        Toggle("Использовать WinBox для этой записи", isOn: $model.settings.enabled)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Подключение").font(.headline)
                            LabeledContent("Адрес") { TextField(model.entry.host, text: $model.settings.host).textFieldStyle(.roundedBorder).accessibilityLabel("Адрес WinBox") }
                            LabeledContent("Порт") { TextField("8291", value: $model.settings.port, format: .number.grouping(.never)).textFieldStyle(.roundedBorder).frame(maxWidth: 110, alignment: .leading).accessibilityLabel("Порт WinBox") }
                            LabeledContent("Пользователь") { TextField(model.entry.user, text: $model.settings.user).textFieldStyle(.roundedBorder).accessibilityLabel("Пользователь WinBox") }
                            Text("Пустые адрес и пользователь берутся из записи. Порт WinBox по умолчанию — 8291. Пароль вводится в WinBox.").font(.caption).foregroundStyle(.secondary)
                        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Приложение").font(.headline)
                            Text(model.applicationURL?.path ?? "WinBox не найден").font(.callout).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3)
                            ViewThatFits(in: .horizontal) { applicationButtons; VStack(alignment: .leading, spacing: 8) { Button("Выбрать WinBox.app…") { model.chooseApplication() }; Button("Найти установленный") { model.detectApplication() }; Link("Скачать у MikroTik", destination: WinboxApplication.downloadURL) } }
                        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Через SSH-туннель", isOn: Binding(get: { model.settings.tunnel != nil }, set: { model.settings.tunnel = $0 ? RecordTunnelSettings(sshID: "") : nil }))
                            if model.settings.tunnel != nil {
                                Picker("SSH-шлюз", selection: Binding(get: { model.settings.tunnel?.sshID ?? "" }, set: { model.settings.tunnel = RecordTunnelSettings(sshID: $0) })) {
                                    Text("Выбери SSH-запись").tag("")
                                    if let id = model.settings.tunnel?.sshID, !id.isEmpty, !model.gateways.contains(where: { $0.canSSH && $0.favoriteID == id }) { Text("Шлюз недоступен").tag(id) }
                                    ForEach(model.gateways.filter(\.canSSH), id: \.favoriteID) { gateway in Text(gateway.name + " · " + gateway.host).tag(gateway.favoriteID) }
                                }
                                Text("Локальный TCP-порт выбирается автоматически. Если туннель не откроется, WinBox не запускается напрямую.").font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(12).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                    }.padding(16).disabled(!model.loadSucceeded || model.busy || model.running)
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    if let error = model.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if !model.loadSucceeded {
                        Text("Редактирование и запуск доступны после успешного чтения настроек. Существующий файл сохранён.").font(.caption).foregroundStyle(.secondary)
                        Button("Повторить чтение") { model.reload() }
                    }
                    HStack {
                        if model.busy { ProgressView().controlSize(.small) }
                        Text(model.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                        Spacer()
                        if model.busy || model.running { Button("Остановить") { model.stop() }; if model.running { Button("Показать WinBox") { model.showApplication() } } }
                        else { Button("Открыть WinBox") { model.start() }.disabled(!model.loadSucceeded || !model.settings.enabled || model.settings.validation != nil || model.applicationURL == nil) }
                    }
                    Text("Закрытие этой вкладки останавливает её туннель и отправляет запрос выхода запущенному экземпляру WinBox. Закрытие только окна WinBox может оставить его процесс работающим: используй Quit в WinBox или «Остановить» здесь.").font(.caption).foregroundStyle(.secondary)
                }.padding(12)
            }.frame(width: viewport.size.width, height: viewport.size.height, alignment: .topLeading)
        }
    }
    private var applicationButtons: some View {
        HStack { Button("Выбрать WinBox.app…") { model.chooseApplication() }; Button("Найти установленный") { model.detectApplication() }; Link("Скачать у MikroTik", destination: WinboxApplication.downloadURL) }
    }
}
