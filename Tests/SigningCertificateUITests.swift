import SwiftUI

// Isolated, read-only UI host. It verifies the explicitly selected build, never user credentials.
@main struct SigningCertificateQA: App {
    @StateObject private var model: SigningCertificateModel
    init() {
        let target = Bundle.main.object(forInfoDictionaryKey: "QAAppPath") as? String
        _model = StateObject(wrappedValue: SigningCertificateModel(verify: {
            guard let target else { throw UpdateError("Не задана временная сборка для проверки.") }
            try DeveloperIDSignature.validate(URL(fileURLWithPath: target))
        }))
    }
    var body: some Scene {
        WindowGroup("SSH Hub Developer ID QA") {
            SigningCertificateSettings(model: model).padding(24).frame(width: 480, height: 180)
        }
    }
}
