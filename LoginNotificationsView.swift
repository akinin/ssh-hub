import SwiftUI

struct LoginNotificationsView: View {
    @ObservedObject var model: LoginNotificationModel
    @Environment(\.dismiss) private var dismiss
    @State private var threadText: String

    init(model: LoginNotificationModel) {
        self.model = model
        _threadText = State(initialValue: model.configuration.messageThreadID.map(String.init) ?? "")
    }
    private var state: String { model.status?.state ?? "" }
    private var editable: Bool { ["absent", "managed", "legacy"].contains(state) }
    private var threadError: String? {
        let text = threadText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(text), (1...2_147_483_647).contains(value) else { return "ID темы должен быть целым числом от 1 до 2147483647. Для чата без темы оставь поле пустым." }
        return nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let review = model.review { reviewContent(review) }
                    else {
                        if let status = model.status { statusContent(status) }
                        else {
                            Label("Состояние ещё не проверено", systemImage: "questionmark.circle").font(.headline)
                            Text("Проверь состояние на сервере, чтобы увидеть существующие уведомления и доступные действия.").foregroundStyle(.secondary)
                        }
                        if editable { configuration }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(22)
            }
            progressAndErrors
            Divider()
            footer
        }.frame(width: 850, height: 650)
            .textFieldStyle(.roundedBorder)
            .interactiveDismissDisabled(model.busy)
            .onChange(of: threadText) { _, text in
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.configuration.messageThreadID = nil }
                else if threadError == nil { model.configuration.messageThreadID = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) }
            }
            .onChange(of: model.configuration.messageThreadID) { _, value in threadText = value.map(String.init) ?? "" }
            .onDisappear { model.stop() }
    }
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bell.badge").font(.title2).foregroundStyle(.tint).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text("Уведомления о входе").font(.title2.bold())
                Text(model.entryTitle + " · " + model.destination).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                Text("Настройка Telegram-уведомлений о входе по SSH. Нужна SSH-запись с пользователем root.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(22)
    }
    private func statusContent(_ status: LoginNotificationStatus) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                Label(statusTitle(status.state), systemImage: statusIcon(status.state)).font(.headline)
                Spacer(minLength: 12)
                Button { model.inspect() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).disabled(model.busy).help("Проверить состояние").accessibilityLabel("Обновить состояние уведомлений")
            }
            if ["managed", "legacy"].contains(status.state) {
                Label(status.enabled ? "Уведомления включены" : "Уведомления выключены", systemImage: status.enabled ? "bell.fill" : "bell.slash")
                    .font(.callout).foregroundStyle(status.enabled ? Color.green : Color.secondary)
            }
            if status.state == "foreign" {
                Text("Найдена другая или неподдерживаемая установка. Доступна только проверка состояния; изменение и удаление из SSH Hub недоступны.")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if status.state == "legacy" {
                Text("Существующие уведомления можно перенести в управление SSH Hub после просмотра плана.").font(.callout).foregroundStyle(.secondary)
                Toggle("Перенести существующие уведомления в управление SSH Hub", isOn: $model.adoptLegacy).disabled(model.busy)
            } else if !["absent", "managed"].contains(status.state) {
                Text("Тип установки не распознан. Доступна только повторная проверка состояния.").font(.callout).foregroundStyle(.orange)
            }
            if let delivery = status.delivery {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Последняя отправка: " + deliveryTitle(delivery.state)).font(.callout)
                    if let date = delivery.date, !date.isEmpty { Text(date).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            ForEach(Array(status.warnings.enumerated()), id: \.offset) { _, warning in
                Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if !status.paths.isEmpty {
                DisclosureGroup("Связанные файлы") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(status.paths.enumerated()), id: \.offset) { _, path in Text(verbatim: path).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
                }.font(.callout)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var configuration: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Telegram").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow { Text("ID чата"); TextField("ID чата или группы", text: $model.configuration.chatID).accessibilityLabel("ID чата Telegram") }
                GridRow { Text("Имя сервера"); TextField("Название в уведомлении", text: $model.configuration.hostLabel) }
                GridRow { Text("Метка"); TextField("Метка уведомления", text: $model.configuration.tag) }
                GridRow { Text("ID темы"); TextField("Необязательно", text: $threadText).accessibilityLabel("ID темы Telegram, необязательно") }
                GridRow { Text("Токен бота"); SecureField(model.status?.hasToken == true ? "Пустое поле сохраняет токен на сервере" : "Токен Telegram-бота", text: $model.token).accessibilityLabel("Новый токен Telegram-бота") }
            }
            if let threadError { Text(threadError).font(.caption).foregroundStyle(.orange) }
            Text(model.status?.hasToken == true
                 ? "Токен уже есть на сервере. Оставь поле пустым, чтобы сохранить его. Сохранённый токен не загружается в это поле."
                 : "Для установки укажи токен Telegram-бота. Токен передаётся только при применении просмотренного плана.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            LoginNotificationMessageEditor(configuration: $model.configuration, user: model.entry.user)
            if let issue = model.configuration.validation { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.disabled(model.busy)
    }
    private func reviewContent(_ review: LoginNotificationPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Проверь изменения перед применением", systemImage: "checklist").font(.headline)
            if review.action == .remove {
                Text("Будут удалены только указанные в плане файлы и настройка уведомлений. Проверь точные пути и сервер.").font(.callout).foregroundStyle(.orange)
            }
            LoginNotificationReviewSummary(review: review)
        }
    }
    @ViewBuilder private var progressAndErrors: some View {
        if model.busy || !model.message.isEmpty || model.error != nil {
            VStack(alignment: .leading, spacing: 8) {
                if model.busy {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(model.operation.isEmpty ? "Выполняется…" : model.operation).font(.callout)
                        Spacer()
                        Button("Остановить") { model.stop() }
                    }
                }
                if !model.message.isEmpty { Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.bottom, 14)
        }
    }
    private var footer: some View {
        HStack(spacing: 10) {
            if model.review != nil {
                Button("Назад") { model.dismissReview() }.disabled(model.busy)
            }
            Button("Закрыть") { model.stop(); dismiss() }.keyboardShortcut(.cancelAction)
            Spacer(minLength: 12)
            if let review = model.review {
                Button(role: review.action == .remove ? .destructive : nil) { model.applyReviewed() } label: { Text(review.action.title) }
                    .buttonStyle(.borderedProminent).tint(review.action == .remove ? Color.red : Color.accentColor).disabled(model.busy)
            } else if model.status == nil {
                Button("Проверить состояние") { model.inspect() }.buttonStyle(.borderedProminent).disabled(model.busy)
            } else if state == "absent" {
                prepareButton(.install, title: "Установить…", prominent: true)
            } else if state == "legacy" {
                prepareButton(.install, title: "Перенести в SSH Hub…", prominent: true).disabled(!model.adoptLegacy)
            } else if state == "managed" {
                prepareButton(.remove, title: "Удалить…", destructive: true)
                prepareButton(model.status?.enabled == true ? .disable : .enable, title: model.status?.enabled == true ? "Выключить…" : "Включить…")
                prepareButton(.configure, title: "Сохранить настройки…", prominent: true)
            }
        }.padding(18)
    }
    @ViewBuilder private func prepareButton(_ action: LoginNotificationAction, title: String, prominent: Bool = false, destructive: Bool = false) -> some View {
        let button = Button(role: destructive ? .destructive : nil) { model.prepare(action) } label: { Text(title) }
            .disabled(model.busy || (action == .install || action == .configure) && threadError != nil)
        if prominent { button.buttonStyle(.borderedProminent) }
        else { button.buttonStyle(.bordered).tint(destructive ? Color.red : nil) }
    }
    private func statusTitle(_ state: String) -> String {
        switch state { case "absent": return "Уведомления не установлены"; case "managed": return "Под управлением SSH Hub"; case "legacy": return "Найдены существующие уведомления"; case "foreign": return "Другая установка"; default: return "Неизвестное состояние" }
    }
    private func statusIcon(_ state: String) -> String {
        switch state { case "absent": return "bell.slash"; case "managed": return "checkmark.shield"; case "legacy": return "arrow.triangle.2.circlepath"; default: return "exclamationmark.shield" }
    }
    private func deliveryTitle(_ state: String) -> String {
        switch state.lowercased() {
        case "ok", "success", "sent", "delivered": return "отправлено"
        case "error", "failed": return "ошибка отправки"
        case "ready": return "служба готова"
        case "retry": return "ожидается повторная попытка"
        case "pending", "queued": return "ожидается"
        case "skipped": return "пропущено"
        case "unknown", "none", "never": return "нет сведений"
        default: return "статус не распознан"
        }
    }
}

struct LoginNotificationMessageEditor: View {
    @Binding var configuration: LoginNotificationConfiguration
    let user: String
    private var zones: [String] { Array(Set(TimeZone.knownTimeZoneIdentifiers + ["UTC", configuration.effectiveTimeZone])).sorted() }
    private var regions: [String] { Array(Set(zones.map { $0.components(separatedBy: "/")[0] })).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Время и текст уведомления").font(.headline)
            HStack {
                Text("Часовой пояс")
                TextField("Asia/Tbilisi", text: Binding(get: { configuration.effectiveTimeZone }, set: { configuration.timeZone = $0 })).accessibilityIdentifier("notificationTimeZone")
                Menu {
                    ForEach(regions, id: \.self) { region in
                        Menu(region) { ForEach(zones.filter { $0.components(separatedBy: "/")[0] == region }, id: \.self) { zone in Button(zone) { configuration.timeZone = zone } } }
                    }
                } label: { Image(systemName: "globe") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Выбрать часовой пояс")
            }
            HStack { Text("На этом Mac: " + TimeZone.current.identifier).font(.caption).foregroundStyle(.secondary); Button("Определить автоматически") { configuration.timeZone = TimeZone.current.identifier }.controlSize(.small) }
            Text("Текст сообщения").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { configuration.effectiveTemplate }, set: { configuration.messageTemplate = $0 }))
                .font(.system(.body, design: .monospaced)).frame(minHeight: 170, maxHeight: 230).padding(6)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("notificationMessageTemplate")
            Text("Меняй подписи, удаляй строки и добавляй свои поля или метки, например #PVE_Olshaniki. Вместо переменных подставятся данные входа.").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 165), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(LoginNotificationMessage.variables, id: \.0) { variable in
                    Button("{" + variable.0 + "} · " + variable.1) { configuration.messageTemplate = configuration.effectiveTemplate + "{" + variable.0 + "}" }
                        .font(.caption).help("Добавить переменную в конец текста")
                }
            }
            HStack { Text("Предпросмотр · пример данных").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Стандартный текст") { configuration.messageTemplate = nil }.controlSize(.small) }
            Text(verbatim: LoginNotificationMessage.preview(configuration, user: user)).font(.callout).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

struct LoginNotificationReviewSummary: View {
    let review: LoginNotificationPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(review.summaryText).font(.callout)
            if review.action == .install || review.action == .configure {
                Text("Чат: " + review.configuration.chatID + " · Сервер: " + review.configuration.hostLabel).font(.caption).foregroundStyle(.secondary)
                Text("Часовой пояс: " + (review.configuration.timeZone ?? "UTC")).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: LoginNotificationMessage.preview(review.configuration, user: review.entry.user)).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Настройки входа SSH, пакеты, firewall и общие уведомления Proxmox не меняются.").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("Технические подробности: пути, команда и исходники") {
                Text(verbatim: review.reviewText).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
            }.font(.caption)
        }
    }
}
