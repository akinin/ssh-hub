import Foundation
import CryptoKit

@main struct LoginNotificationTests {
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw ConfigError.message("Login notification test: " + message) }
    }
    static func rejects(_ action: () throws -> Void, _ message: String) throws {
        do { try action() } catch { return }
        throw ConfigError.message("Login notification test: expected rejection: " + message)
    }
    static func data(_ object: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    static func object(_ data: Data) throws -> [String: Any] { try JSONSerialization.jsonObject(with: data) as! [String: Any] }
    static let token = "123456:" + String(repeating: "A", count: 32)
    static let revision = String(repeating: "a", count: 64)
    static func configuration() -> LoginNotificationConfiguration {
        LoginNotificationConfiguration(chatID: "-1001234567890", hostLabel: "Synthetic server", tag: "SSH_Login", messageThreadID: 42)
    }
    static func status(_ state: String = "managed") throws -> [String: Any] {
        ["schema": 1, "state": state, "enabled": true, "has_token": true,
         "configuration": try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration())),
         "revision": revision, "paths": ["/etc/ssh-hub-login-notify/config.json"], "warnings": [],
         "delivery": ["state": "sent", "date": "2026-01-01T12:00:00Z"]]
    }
    static func response(_ status: [String: Any]) throws -> Data { try data(["ok": true, "status": status]) }

    @MainActor static func main() throws {
        var configuration = configuration()
        try require(configuration.validation == nil, "valid group, host, tag and topic")
        for chat in ["1", "-1", "-1001234567890", "@synthetic_channel", "@a1234", "@a" + String(repeating: "x", count: 31), String(repeating: "9", count: 19)] {
            configuration.chatID = chat; try require(configuration.validation == nil, "valid chat ID")
        }
        for chat in ["", " ", "-", "0", "-0", "01", "-01", "@abc", "@1channel", "@channel-name", "@a" + String(repeating: "x", count: 32), "1;id", "1\n", "1\r\n", "1\0", String(repeating: "9", count: 20)] {
            configuration.chatID = chat; try require(configuration.validation != nil, "reject malformed or control-bearing chat ID")
        }
        configuration = self.configuration()
        for host in ["", "   ", "server\n", "server\t", "server\0", String(repeating: "Ж", count: 101)] {
            configuration.hostLabel = host; try require(configuration.validation != nil, "reject invalid host label by UTF-8 size/controls")
        }
        configuration.hostLabel = String(repeating: "Ж", count: 100)
        try require(configuration.validation == nil, "host label UTF-8 boundary")
        configuration = self.configuration()
        for tag in ["", "SSH_Login", "SSH-Login", "Узел_01", String(repeating: "x", count: 80), String(repeating: "Ж", count: 40)] { configuration.tag = tag; try require(configuration.validation == nil, "valid optional tag and UTF-8 boundary") }
        for tag in ["#SSH", "SSH Login", "SSH\n", String(repeating: "x", count: 81), String(repeating: "Ж", count: 41)] { configuration.tag = tag; try require(configuration.validation != nil, "reject invalid tag and UTF-8 overflow") }
        configuration = self.configuration()
        for topic in [1, 2_147_483_647] { configuration.messageThreadID = topic; try require(configuration.validation == nil, "topic lower and upper bounds") }
        for topic in [0, -1, 2_147_483_648] { configuration.messageThreadID = topic; try require(configuration.validation != nil, "topic outside supported range") }
        configuration.messageThreadID = nil; try require(configuration.validation == nil, "topic optional")
        try require(LoginNotificationConfiguration.validToken(token), "synthetic token accepted")
        for valid in ["1234:" + String(repeating: "a", count: 20), String(repeating: "9", count: 20) + ":" + String(repeating: "a", count: 200)] { try require(LoginNotificationConfiguration.validToken(valid), "token bot ID and suffix boundary") }
        for bad in ["", "123:" + String(repeating: "a", count: 20), String(repeating: "9", count: 21) + ":" + String(repeating: "a", count: 20), "12345:" + String(repeating: "a", count: 19), "12345:" + String(repeating: "a", count: 201), token + "\n", token + "\r\n", token + " ", " " + token, token + "\0", "12345:" + String(repeating: "Ж", count: 20)] {
            try require(!LoginNotificationConfiguration.validToken(bad), "reject malformed or control-bearing token")
        }
        let encoded = try object(JSONEncoder().encode(self.configuration()))
        try require(Set(encoded.keys) == ["chat_id", "host_label", "tag", "message_thread_id"], "stable snake-case wire configuration without secrets")
        try require(try JSONDecoder().decode(LoginNotificationConfiguration.self, from: JSONEncoder().encode(self.configuration())) == self.configuration(), "configuration round trip")

        var messageConfig = self.configuration()
        messageConfig.timeZone = "Asia/Tbilisi"
        messageConfig.messageTemplate = "#PVE_Olshaniki\nУзел: {server}\nКто: {user}\nIP: {ip}\nКогда: {time} ({timezone})\n{terminal} {service} {tag}"
        try require(messageConfig.validation == nil, "free labels, tags and allowlisted variables")
        let preview = LoginNotificationMessage.preview(messageConfig, user: "fixture", date: Date(timeIntervalSince1970: 1735732800))
        try require(preview.contains("16:00:00 +0400") && preview.contains("#PVE_Olshaniki") && preview.contains("192.0.2.10"), "local time and synthetic variable preview")
        var messageStatus = try status(); messageStatus["configuration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messageConfig))
        try require(try LoginNotificationFailure.decode(response(messageStatus)).configuration == messageConfig, "multiline public template decodes safely")
        for invalid in ["", "{unknown}", "{user.name}", "{time:format}", "{user!r}", "{user", "value\r", String(repeating: "Ж", count: 1025)] {
            messageConfig.messageTemplate = invalid; try require(messageConfig.validation != nil, "template bounds and grammar")
        }
        messageConfig.messageTemplate = "{user}"; messageConfig.timeZone = "Invalid/Zone"
        try require(messageConfig.validation != nil, "unknown timezone rejected")
        messageConfig.timeZone = "America/New_York"
        try require(LoginNotificationMessage.preview(messageConfig, user: "{ip}") == "{ip}", "single-pass expansion")
        messageConfig.messageTemplate = self.token
        messageStatus["configuration"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(messageConfig))
        try rejects({ _ = try LoginNotificationFailure.decode(response(messageStatus)) }, "template cannot return token")
        for state in ["absent", "managed", "legacy", "foreign"] {
            let decoded = try LoginNotificationFailure.decode(response(status(state)))
            try require(decoded.state == state && decoded.hasToken && decoded.configuration.messageThreadID == 42, "decode supported states without remote token")
        }
        var absent = try status("absent"); absent["has_token"] = false; absent["enabled"] = false
        absent["configuration"] = ["chat_id": "", "host_label": "", "tag": ""]
        absent.removeValue(forKey: "delivery")
        try require(try LoginNotificationFailure.decode(response(absent)).configuration.chatID.isEmpty, "absent installation permits empty public configuration")
        for (key, value) in [("schema", 2 as Any), ("schema", true as Any), ("state", "other" as Any), ("revision", String(repeating: "a", count: 63) as Any), ("revision", String(repeating: "a", count: 64) + "\n" as Any), ("paths", Array(repeating: "/etc/synthetic", count: 33) as Any), ("paths", [String(repeating: "x", count: 513)] as Any), ("paths", ["/etc/unsafe\npath"] as Any), ("warnings", Array(repeating: "warning", count: 21) as Any), ("warnings", [String(repeating: "x", count: 1001)] as Any), ("delivery", ["state": String(repeating: "x", count: 101)] as Any)] {
            var bad = try status(); bad[key] = value
            try rejects({ _ = try LoginNotificationFailure.decode(response(bad)) }, "status bounds/schema")
        }
        for key in ["chat_id", "host_label", "tag"] {
            var bad = try status(), config = bad["configuration"] as! [String: Any]
            config[key] = String(repeating: "x", count: key == "host_label" ? 201 : 101); bad["configuration"] = config
            try rejects({ _ = try LoginNotificationFailure.decode(response(bad)) }, "public configuration bounds")
        }
        var secretStatus = try status(); secretStatus["warnings"] = [token]
        try rejects({ _ = try LoginNotificationFailure.decode(response(secretStatus)) }, "literal token cannot enter public status")
        let escapedToken = String(decoding: try response(secretStatus), as: UTF8.self).replacingOccurrences(of: "123456:", with: "123456\\u003a")
        try rejects({ _ = try LoginNotificationFailure.decode(Data(escapedToken.utf8)) }, "JSON-escaped token cannot bypass secret filter")
        let minimumToken = "1234:" + String(repeating: "a", count: 20)
        secretStatus["warnings"] = [minimumToken]
        try rejects({ _ = try LoginNotificationFailure.decode(response(secretStatus)) }, "minimum-size supported token also filtered from public status")
        let escapedMinimum = String(decoding: try response(secretStatus), as: UTF8.self).replacingOccurrences(of: minimumToken, with: "1234\\u003a" + String(repeating: "a", count: 20))
        try rejects({ _ = try LoginNotificationFailure.decode(Data(escapedMinimum.utf8)) }, "minimum-size token filtered after JSON unescape")
        for secretKey in ["token", "bot_token", "secret"] {
            var bad = try status(); bad[secretKey] = "synthetic-value"
            try rejects({ _ = try LoginNotificationFailure.decode(response(bad)) }, "secret-bearing unknown status keys rejected")
        }
        for control in ["\0", "\u{1b}[31m", "\n"] {
            var bad = try status(); bad["warnings"] = ["synthetic" + control]
            try rejects({ _ = try LoginNotificationFailure.decode(response(bad)) }, "escaped decoded controls cannot enter public warning")
        }
        try rejects({ _ = try LoginNotificationFailure.decode(data(["ok": 1, "status": status()])) }, "numeric success flag is not a JSON boolean")
        try rejects({ _ = try LoginNotificationFailure.decode(data(["ok": false, "error": "invalid_token", "detail": token])) }, "failure envelope rejected")
        try rejects({ _ = try LoginNotificationFailure.decode(Data(repeating: 32, count: 16_385)) }, "oversized response rejected before decode")
        try rejects({ _ = try LoginNotificationFailure.decode(Data([0xff, 0xfe])) }, "non-UTF-8 response rejected")
        let unknownFailure = try data(["error": token, "detail": token])
        try require(!LoginNotificationFailure.message(unknownFailure).contains(token), "untrusted remote failure detail is never echoed")
        for code in ["stale_revision", "revision_changed"] { try require(LoginNotificationFailure.message(try data(["error": code])).contains("изменилось"), "actual and legacy stale revision codes map to fixed guidance") }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("login-notification-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config"), include = root.appendingPathComponent("include.conf")
        try Data(("Include " + include.path + "\nHost fixture_notification\n HostName 192.0.2.42\n User root\n").utf8).write(to: config)
        try Data("Host *\n Port 22\n".utf8).write(to: include)
        for file in [config, include] { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }
        var entry = SSHAlias(name: "fixture_notification", source: config, line: 2, options: [SSHOption(key: "HostName", value: "192.0.2.42"), SSHOption(key: "User", value: "root")])
        let snapshot = try MaintenanceConfigSnapshot.capture(roots: [config])
        var previous = try LoginNotificationFailure.decode(response(status()))
        configuration = self.configuration()
        var manager = "import json,sys\n# synthetic manager's stdin only\nrequest=json.load(sys.stdin)\n"
        var helper = Data("# synthetic notification helper\n".utf8)
        func plan(_ action: LoginNotificationAction, newToken: String? = token, adopt: Bool = false, helper: Data? = nil) -> LoginNotificationPlan {
            LoginNotificationPlan(action: action, entry: entry, fingerprint: MaintenancePlan.fingerprint(entry), snapshot: snapshot,
                                  revision: previous.revision, configuration: configuration, newToken: newToken, adoptLegacy: adopt,
                                  manager: manager, helper: helper ?? selfHelper(), previous: previous)
        }
        func selfHelper() -> Data { helper }
        let reviewed = plan(.configure)
        let payload = try object(reviewed.payload())
        try require(payload["token"] as? String == token && payload["action"] as? String == "configure" && payload["expected_revision"] as? String == revision, "secret and revision carried in private stdin payload")
        try require(!reviewed.reviewText.contains(token) && !reviewed.remoteCommand.contains(token), "secret absent from review and command arguments")
        try require(reviewed.remoteCommand == "/usr/bin/python3 -I -B -c " + SSHConfig.shellQuote(manager), "isolated Python without bytecode and safely quoted immutable manager")
        try require(payload["helper"] as? String == helper.base64EncodedString() && payload["helper_sha256"] as? String == SHA256.hash(data: helper).map({ String(format: "%02x", $0) }).joined(), "helper payload hash binds reviewed bytes")
        for action in LoginNotificationAction.allCases {
            let proposed = plan(action)
            try require(try object(proposed.payload())["action"] as? String == action.rawValue, "every action remains explicit")
            try require(proposed.reviewText.contains(action.title) && proposed.reviewText.contains("root@192.0.2.42:22"), "review includes action and exact recipient")
        }
        try require(try object(plan(.configure, newToken: nil).payload())["token"] == nil, "blank replacement omits token so server preserves existing secret")
        let migration = plan(.install, newToken: nil, adopt: true)
        try require(try object(migration.payload())["adopt_legacy"] as? Bool == true && migration.reviewText.contains("/usr/local/sbin/ssh-login-telegram") && migration.reviewText.contains("/etc/ssh-login-telegram.conf"), "legacy migration requires explicit flag and exact known targets")
        let removal = plan(.remove, newToken: nil)
        for path in ["/etc/pam.d/sshd", "/usr/local/lib/ssh-hub-login-notify/", "/etc/ssh-hub-login-notify/", "/var/lib/ssh-hub-login-notify/", "/etc/systemd/system/ssh-hub-login-notify.service"] { try require(removal.reviewText.contains(path), "removal previews exact managed targets") }
        try rejects({ _ = try plan(.install, helper: Data(repeating: 65, count: 200_000)).payload() }, "oversized stdin plan refused")
        configuration.hostLabel = "UNAPPLIED_DRAFT_HOST"; configuration.chatID = "-2000000000"; configuration.messageThreadID = 999
        let expectedPublicConfig = try JSONSerialization.jsonObject(with: JSONEncoder().encode(previous.configuration))
        for action in [LoginNotificationAction.enable, .disable, .remove] {
            let existingOnly = plan(action), body = try object(existingOnly.payload())
            try require(existingOnly.configuration == previous.configuration && existingOnly.newToken == nil, "non-config actions snapshot actual remote settings and omit unused typed token")
            try require(body["token"] == nil && (body["config"] as? NSDictionary)?.isEqual(expectedPublicConfig) == true, "non-config stdin excludes unsaved settings and new secret")
            try require(!existingOnly.reviewText.contains("UNAPPLIED_DRAFT_HOST") && !existingOnly.reviewText.contains(token), "non-config review matches applied settings without unsaved draft or secret")
        }
        configuration = reviewed.configuration
        configuration.hostLabel = "Edited after review"; configuration.chatID = "-2000000000"; previous.revision = String(repeating: "b", count: 64)
        manager += "# changed\n"; helper.append(10); entry.options.append(SSHOption(key: "ProxyJump", value: "synthetic-gateway"))
        try require(reviewed.configuration == self.configuration() && reviewed.revision == revision && reviewed.previous.revision == revision && reviewed.manager != manager && reviewed.helper != helper, "reviewed configuration, revision, source and helper are immutable snapshots")
        try require(reviewed.fingerprint != MaintenancePlan.fingerprint(entry), "SSH route change invalidates reviewed target")
        var changed = reviewed.entry; changed.options = changed.options.filter { $0.key != "User" } + [SSHOption(key: "User", value: "operator")]
        try require(reviewed.fingerprint != MaintenancePlan.fingerprint(changed), "login user change invalidates target")
        changed = reviewed.entry; changed.sharedCredentialScope = "synthetic-new-preset"
        try require(reviewed.fingerprint != MaintenancePlan.fingerprint(changed), "shared credential binding invalidates target")
        try reviewed.snapshot.validate()
        try Data("Host *\n Port 2222\n".utf8).write(to: include)
        try rejects({ try reviewed.snapshot.validate() }, "included SSH config changed after review")

        let resources = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        try Data("# synthetic manager\n".utf8).write(to: resources.appendingPathComponent("manage.py")); try helper.write(to: resources.appendingPathComponent("notify.py"))
        var resolved: SSHAlias? = reviewed.entry
        let model = LoginNotificationModel(entry: reviewed.entry, title: "Synthetic server", config: config, resources: resources, resolveEntry: { resolved })
        try require(!model.busy && model.status == nil && model.review == nil && !LoginNotificationModel.pending, "opening model has no remote operation")
        model.prepare(.configure)
        try require(!model.busy && model.review == nil && model.error != nil && !LoginNotificationModel.pending, "uninspected mutation refused without starting SSH")
        model.token = token; model.close()
        try require(model.token.isEmpty && model.review == nil && !LoginNotificationModel.pending, "close clears local secret without a remote read or mutation")
        resolved?.options.append(SSHOption(key: "ProxyJump", value: "new-synthetic-gateway")); model.token = token; model.refreshBinding()
        try require(model.token.isEmpty && model.status == nil && model.error != nil && !LoginNotificationModel.pending, "changed SSH route invalidates model and clears secret before any transport")
        resolved = nil; model.token = token; model.refreshBinding()
        try require(model.token.isEmpty && model.status == nil && model.error != nil && !LoginNotificationModel.pending, "record removed from profile invalidates model without SSH")
        print("Login notification tests passed")
    }
}
