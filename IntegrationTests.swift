import Foundation

@main struct IntegrationTests {
    static func main() {
        assert(IntegrationAction(url: URL(string: "ssh-hub://generate-key")!) == .generateKey)
        assert(IntegrationAction(url: URL(string: "ssh-hub://keys/")!) == .keys)
        for value in ["https://keys", "ssh-hub://install", "ssh-hub://keys/run", "ssh-hub://keys?command=ssh", "ssh-hub://user@keys", "ssh-hub://keys:22", "ssh-hub://keys#run"] {
            assert(IntegrationAction(url: URL(string: value)!) == nil, value)
        }
        assert(IntegrationAction.launchAction(arguments: ["SSHHub", "--integration-action", "keys"]) == .keys)
        assert(IntegrationAction.launchAction(arguments: ["SSHHub", "--integration-action"]) == nil)
        assert(IntegrationAction.launchAction(arguments: ["SSHHub", "--integration-action", "install"]) == nil)
        print("Integration tests passed: tool routing and rejection of command-like links")
    }
}
