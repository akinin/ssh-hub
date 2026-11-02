import Foundation
import Security

@main enum SigningCertificateTests {
    @MainActor static func main() throws {
        precondition(DeveloperIDSignature.teamID == "T3V8ZUE97C")
        precondition(DeveloperIDSignature.requirementText.contains("anchor apple generic"))
        precondition(DeveloperIDSignature.requirementText.contains("1.2.840.113635.100.6.1.13"))
        precondition(DeveloperIDSignature.requirementText.contains("1.2.840.113635.100.6.2.6"))
        var requirement: SecRequirement?
        precondition(SecRequirementCreateWithString(DeveloperIDSignature.requirementText as CFString, [], &requirement) == errSecSuccess)
        var allowed = false
        var calls = 0
        let model = SigningCertificateModel(verify: {
            calls += 1
            if !allowed { throw UpdateError("Fixture: signature rejected") }
        })
        model.refresh(); precondition(!model.trusted && model.error != nil && calls == 1)
        allowed = true
        model.refresh(); precondition(model.trusted && model.error == nil && calls == 2)
        allowed = false
        model.refresh(); precondition(!model.trusted && model.error != nil && calls == 3)
        do { try DeveloperIDSignature.validate(URL(fileURLWithPath: "/private/tmp/ssh-hub-nonexistent-signed-app-" + UUID().uuidString)); preconditionFailure() }
        catch {}
        if CommandLine.arguments.count > 1 {
            try DeveloperIDSignature.validate(URL(fileURLWithPath: CommandLine.arguments[1]))
            if CommandLine.arguments.count > 2 {
                do { try DeveloperIDSignature.validate(URL(fileURLWithPath: CommandLine.arguments[2])); preconditionFailure("Legacy signer accepted") }
                catch {}
            }
            print("Actual Developer ID app accepted; legacy publisher rejected.")
        }
        print("Developer ID checks passed: Apple/team/type requirement compiles, failed and recovered read-only status, missing app rejected. No trust settings changed.")
    }
}
