import SwiftUI

struct HistoryView: View {
    @EnvironmentObject var store: AliasStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingClear = false
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("История подключений", systemImage: "clock.arrow.circlepath").font(.title2).bold()
                Spacer()
                Button("Очистить", systemImage: "trash") { confirmingClear = true }.disabled(store.history.isEmpty)
            }
            Text("Последние запуски SSH и SFTP. Запись означает открытие терминала, а не успешную авторизацию на сервере.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if store.history.isEmpty {
                ContentUnavailableView("История пока пуста", systemImage: "clock", description: Text("Открой SSH или SFTP из приложения — подключение появится здесь."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(store.history) { record in
                    HStack(spacing: 14) {
                        Image(systemName: record.kind == .ssh ? "terminal" : "folder").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(store.alias(for: record).map { store.title($0) } ?? record.name).font(.body).lineLimit(1)
                            Text(record.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().locale(Locale(identifier: "ru_RU"))))
                                .font(.caption).foregroundStyle(.secondary)
                            if store.alias(for: record) == nil { Text("Алиас больше не доступен").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 8)
                        Text(record.kind.title).font(.caption).foregroundStyle(.secondary)
                        Button("Открыть") { store.repeatConnection(record) }.disabled(store.alias(for: record) == nil)
                        Button {
                            if let entry = store.alias(for: record) {
                                store.query = ""; store.groupFilter = "all"; store.selected = entry.id; dismiss()
                            }
                        } label: { Image(systemName: "arrow.right.circle") }
                            .help("Показать алиас в приложении").disabled(store.alias(for: record) == nil)
                    }.padding(.vertical, 5)
                }.listStyle(.inset)
            }
            HStack {
                Text("До 50 записей. Повторный запуск поднимает подключение вверх.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 720, height: 550)
            .confirmationDialog("Очистить историю подключений?", isPresented: $confirmingClear, titleVisibility: .visible) {
                Button("Очистить историю", role: .destructive) { store.clearHistory() }
                Button("Отмена", role: .cancel) {}
            } message: { Text("SSH-алиасы и избранное сохранятся.") }
    }
}
