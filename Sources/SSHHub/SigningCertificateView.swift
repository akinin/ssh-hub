import SwiftUI
import AppKit

struct SigningCertificateSettings: View {
    @ObservedObject var model = SigningCertificateModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Подпись приложения").font(.headline)
            if model.trusted {
                Label("Apple Developer ID · Anton Akinin", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                Text("Подпись проверена. Устанавливать сертификат вручную не требуется.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Подпись Developer ID не подтверждена", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                if let error = model.error {
                    Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
    }
}
