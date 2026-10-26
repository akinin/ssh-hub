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
    @StateObject private var offer: SigningCertificateOffer
    init() {
        let fixture = FixtureTrust(Bundle.main.object(forInfoDictionaryKey: "QAInitiallyTrusted") as? Bool ?? false)
        let data = try! Data(contentsOf: Bundle.main.url(forResource: "SSHHub-CodeSigning", withExtension: "cer")!)
        let fail = Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false
        let defaults = UserDefaults(suiteName: "com.olshaniki.sshhub.certqa.launch-owned")!
        defaults.removePersistentDomain(forName: "com.olshaniki.sshhub.certqa.launch-owned")
        _offer = StateObject(wrappedValue: SigningCertificateOffer(defaults: defaults, read: { data }, evaluate: { _ in fixture.read() }))
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
            if Bundle.main.object(forInfoDictionaryKey: "QAOffer") as? Bool == true {
                Group {
                    if offer.presented { SigningCertificateOfferView(model: model, offer: offer) }
                    else { Text("Предложение сертификата закрыто.").padding(30) }
                }.onAppear { offer.consider() }
            } else {
            VStack(alignment: .leading, spacing: 18) {
                Text("Обновления").font(.title2.bold())
                SigningCertificateSettings(model: model)
                Spacer(minLength: 0)
            }.padding(24).frame(width: (Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false) ? 360 : 520, height: 340)
            }
        }.defaultSize(width: (Bundle.main.object(forInfoDictionaryKey: "QAFailure") as? Bool ?? false) ? 360 : 520, height: 340)
    }
}
