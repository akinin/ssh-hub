import Foundation
import Combine

// Read-only status. Developer ID chains to Apple; the app never installs trust.
@MainActor final class SigningCertificateModel: ObservableObject {
    static let shared = SigningCertificateModel()
    @Published private(set) var trusted = false
    @Published private(set) var error: String?
    private let verify: () throws -> Void
    init(verify: @escaping () throws -> Void = { try DeveloperIDSignature.validate(Bundle.main.bundleURL) }) {
        self.verify = verify
    }
    func refresh() {
        do { try verify(); trusted = true; error = nil }
        catch { trusted = false; self.error = error.localizedDescription }
    }
}
