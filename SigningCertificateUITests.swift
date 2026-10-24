import SwiftUI
import AppKit

// Isolated native QA host. Its button only changes fixture state, never trust settings.
private final class FixtureTrust: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func read() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func installed() { lock.lock(); value = true; lock.unlock() }
}
@main struct SigningCertificateQA: App {
    @StateObject private var model: SigningCertificateModel
    init() {
        let fixture = FixtureTrust(Bundle.main.object(forInfoDictionaryKey: "QAInitiallyTrusted") as? Bool ?? false)
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "SSHHub-CodeSigning", withExtension: "cer")!)
        let fail = Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false
        _model = StateObject(wrappedValue: SigningCertificateModel(read: { data }, evaluate: { _ in fixture.read() }, makeInstallation: {
            SigningCertificateInstallation { _, _ in
                try await Task.sleep(nanoseconds: 400_000_000)
                if fail { throw SigningCertificateError(text: "Тест: подтверждение macOS отменено.") }
                fixture.installed()
            }
        }))
    }
    var body: some Scene {
        WindowGroup("SSH Hub Certificate QA") {
            VStack(alignment: .leading, spacing: 18) {
                Text("Обновления").font(.title2.bold())
                SigningCertificateSettings(model: model)
                Spacer(minLength: 0)
            }.padding(24).frame(width: (Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false) ? 360 : 520, height: 340)
        }.defaultSize(width: (Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false) ? 360 : 520, height: 340)
    }
}
