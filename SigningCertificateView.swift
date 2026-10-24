import SwiftUI
import AppKit

struct SigningCertificateSettings: View {
    @ObservedObject var model = SigningCertificateModel.shared
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Сертификат SSH Hub").font(.headline)
            Text("Установи один раз на этом Mac, чтобы после обновлений сохранялось разрешение доступа к паролям.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.trusted {
                Label("Сертификат установлен", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            }
            HStack(spacing: 12) {
                Button("Установить сертификат…", systemImage: "checkmark.shield") { confirming = true }
                    .disabled(model.busy || model.trusted)
                if model.busy { ProgressView().controlSize(.small); Button("Отменить") { model.cancel() } }
            }
            if !model.message.isEmpty && !model.trusted {
                Text(model.message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .confirmationDialog("Установить сертификат SSH Hub?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Установить") { model.install() }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Сертификат будет добавлен в связку «Вход» с доверием только для подписи кода. macOS может запросить пароль или подтверждение.")
        }
    }
}
