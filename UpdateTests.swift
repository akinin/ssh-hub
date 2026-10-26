import Foundation
import CryptoKit

@main enum UpdateTests {
    static func check(_ value: Bool) { precondition(value) }
    static func reject(_ body: () throws -> Void) { do { try body(); fatalError("unsafe input accepted") } catch {} }
    static func main() async throws {
        check(UpdateTransport.supports("arm64 x86_64", running: "arm64"))
        check(UpdateTransport.supports("x86_64 arm64\n", running: "x86_64"))
        check(!UpdateTransport.supports("arm64", running: "x86_64"))
        check(!UpdateTransport.supports("x86_64", running: "arm64"))
        check(!UpdateTransport.supports("arm64e", running: "arm64"))
        check(!UpdateTransport.supports("arm64 x86_64", running: "unknown"))
        check(ReleaseVersion("v2.10.0")! > ReleaseVersion("2.9.99")!)
        check(ReleaseVersion("2.4.0")! == ReleaseVersion("v2.4.0")!)
        for text in ["2.4", "2.4.0-beta", "1.0.0;id", "-1.0.0", "9999999.0.0"] { check(ReleaseVersion(text) == nil) }
        let zip = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let digest = "sha256:" + SHA256.hash(data: zip).map { String(format: "%02x", $0) }.joined()
        var asset: [String: Any] = ["name": "SSH-Hub-macOS.zip", "state": "uploaded", "size": zip.count, "digest": digest, "browser_download_url": "https://github.com/akinin/ssh-hub/releases/download/v2.4.0/SSH-Hub-macOS.zip"]
        func release(_ asset: [String: Any], prerelease: Bool = false) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["tag_name": "v2.4.0", "html_url": "https://github.com/akinin/ssh-hub/releases/tag/v2.4.0", "draft": false, "prerelease": prerelease, "body": "Changes", "assets": [asset]])
        }
        check(try AvailableUpdate.parse(release(asset), installed: "2.3.1")?.version.string == "2.4.0")
        check(try AvailableUpdate.parse(release(asset), installed: "2.4.0") == nil)
        check(try AvailableUpdate.parse(release(asset), installed: "2.10.0") == nil)
        reject { _ = try AvailableUpdate.parse(release(asset, prerelease: true), installed: "2.3.1") }
        asset["browser_download_url"] = "https://github.com/attacker/ssh-hub/releases/download/v2.4.0/SSH-Hub-macOS.zip"
        reject { _ = try AvailableUpdate.parse(release(asset), installed: "2.3.1") }
        asset["browser_download_url"] = "http://github.com/akinin/ssh-hub/releases/download/v2.4.0/SSH-Hub-macOS.zip"
        reject { _ = try AvailableUpdate.parse(release(asset), installed: "2.3.1") }
        asset["digest"] = NSNull()
        reject { _ = try AvailableUpdate.parse(release(asset), installed: "2.3.1") }
        try UpdateTransport.verifyArchive(zip, expectedDigest: digest)
        reject { try UpdateTransport.verifyArchive(zip, expectedDigest: "sha256:" + String(repeating: "0", count: 64)) }
        var altered = zip; altered[0] ^= 1
        reject { try UpdateTransport.verifyArchive(altered, expectedDigest: digest) }
        reject { try UpdateZIP.validate(Data("not a zip".utf8)) }
        // Change both local and central names to traversal with the same length.
        var traversal = zip
        let original = Data("SSH Hub.app/".utf8), bad = Data("../bad.app//".utf8)
        check(original.count == bad.count)
        var search = traversal.startIndex..<traversal.endIndex
        while let range = traversal.range(of: original, in: search) { traversal.replaceSubrange(range, with: bad); search = range.upperBound..<traversal.endIndex }
        reject { try UpdateZIP.validate(traversal) }
        // A Unix symlink in the central directory must be rejected before extraction.
        var symlink = zip
        if let offset = symlink.range(of: Data([0x50,0x4b,0x01,0x02]))?.lowerBound { symlink[offset + 40] = 0xff; symlink[offset + 41] = 0xa1 }
        reject { try UpdateZIP.validate(symlink) }
        var mismatch = zip
        if let range = mismatch.range(of: original) { mismatch[range.lowerBound] = 88 }
        reject { try UpdateZIP.validate(mismatch) }
        if ProcessInfo.processInfo.environment["SSH_HUB_LIVE_UPDATE"] == "1" {
            let update = try await UpdateTransport.latestRelease(installed: "2.3.0")!
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("SSHHubUpdate-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: root) }
            let archive = try await UpdateTransport.download(update, to: root)
            _ = try UpdateTransport.extract(archive, root: root, version: update.version.string)
            print("Live GitHub Releases check/download/digest/extraction/app validation passed: " + update.version.string)
        }
        print("Update checks passed: numeric versions, stable releases, source URL/digest requirements, real ZIP, corruption, traversal, symlinks and central/local name mismatch")
    }
}
