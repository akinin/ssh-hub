import Foundation
import SwiftUI
import AppKit
import CryptoKit
import Security
import IOKit

@MainActor final class MCPJob: ObservableObject, Identifiable {
    let id = UUID()
    let name: String
    let preview: String
    let profile: UUID
    let epoch: UUID
    let created = Date()
    @Published var status = "pending_approval"
    var result: [String: Any]?
    var action: (@MainActor () async throws -> [String: Any])?
    var cancel: (() -> Void)?
    var task: Task<Void, Never>?
    var expiry: Task<Void, Never>?
    init(name: String, preview: String, profile: UUID, epoch: UUID, action: @escaping @MainActor () async throws -> [String: Any]) {
        self.name = name; self.preview = preview; self.profile = profile; self.epoch = epoch; self.action = action
    }
    var active: Bool { status == "pending_approval" || status == "running" }
    var response: [String: Any] {
        var value: [String: Any] = ["job_id": id.uuidString.lowercased(), "tool": name, "status": status]
        if let result { value["result"] = result }
        if status == "pending_approval" { value["message"] = "Review and approve this request in SSH Hub. The agent cannot approve it." }
        return value
    }
}

/// Authority lives on the main actor with the unlocked workspace, never in the HTTP listener.
@MainActor final class MCPController: ObservableObject {
    weak var store: AliasStore?
    @Published private(set) var configuration = MCPConfiguration()
    @Published private(set) var listening = false
    @Published var error: String?
    @Published private(set) var jobs: [MCPJob] = []
    private let server = MCPHTTPServer()
    private let settingsKey: String
    private let presentReviews: Bool
    private let startListener: Bool
    private let runStep: MaintenanceStepRunner?
    private var epoch = UUID()
    private var listenerID = UUID()
    private var reviewWindow: MCPReviewWindow?
    private var rateStart = Date()
    private var requestCount = 0
    init(store: AliasStore, deviceID: String? = nil, presentReviews: Bool = true, startListener: Bool = true, runStep: MaintenanceStepRunner? = nil) {
        self.store = store; self.presentReviews = presentReviews; self.startListener = startListener; self.runStep = runStep
        let device = deviceID ?? Self.deviceBinding()
        settingsKey = "mcp-local/" + SHA256.hash(data: Data(device.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func deviceBinding() -> String {
        if let root = HubPaths.testingRoot { return "fixture:" + root.path }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if entry != 0 { IOObjectRelease(entry) } }
        // If hardware binding is unavailable, fail closed rather than share a token across Macs.
        guard entry != 0, let value = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String, !value.isEmpty else { return UUID().uuidString }
        return value + ":" + String(getuid())
    }
    private var available: Bool {
        guard let store else { return false }
        return !store.endingWorkspace && !AppAccess.shared.locked && store.portableVault?.unlocked == true && store.portableVault?.database?.unlocked == true
    }
    func resume() {
        guard available, let database = store?.portableVault?.database else { return }
        do {
            configuration = try database.get(settingsKey).map { try JSONDecoder().decode(MCPConfiguration.self, from: $0) } ?? MCPConfiguration()
            guard configuration.valid, !configuration.enabled || configuration.token.count == 64 else { throw MCPFailure.message("Некорректные настройки MCP. Выключи сервер и создай новый ключ доступа.") }
            restart()
        } catch { self.error = "Не удалось прочитать настройки MCP из базы." }
    }
    func save(_ value: MCPConfiguration) {
        guard available, let database = store?.portableVault?.database else { error = "Сначала разблокируй базу."; return }
        do {
            var value = value
            guard value.valid else { throw MCPFailure.message("Укажи порт от 1024 до 65535.") }
            if value.token.isEmpty {
                var bytes = [UInt8](repeating: 0, count: 32)
                guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw MCPFailure.message("Не удалось создать ключ доступа.") }
                value.token = bytes.map { String(format: "%02x", $0) }.joined()
            }
            let transportChanged = value.enabled != configuration.enabled || value.port != configuration.port
            try database.set(settingsKey, JSONEncoder().encode(value)); configuration = value; error = nil
            if transportChanged || value.enabled && !listening { restart() } else { cancelJobs() }
        } catch { self.error = (error as? MCPFailure)?.localizedDescription ?? "Не удалось сохранить настройки MCP в базе." }
    }
    func rotateToken() { var value = configuration; value.token = ""; save(value) }
    var endpoint: String { "http://127.0.0.1:\(configuration.port)/mcp" }
    var clientConfiguration: String {
        let value: [String: Any] = ["mcpServers": ["ssh-hub": ["url": endpoint, "headers": ["Authorization": "Bearer " + configuration.token]]]]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
    private func restart() {
        stopTransport(); guard available, configuration.enabled, startListener else { return }
        let generation = listenerID
        do {
            try server.start(port: UInt16(configuration.port), handler: { [weak self] request in
                guard let self else { return .init(status: 503) }
                return await self.handle(request, listener: generation)
            }, state: { [weak self] ready, error in
                Task { @MainActor in guard let self, self.listenerID == generation else { return }; self.listening = ready; if let error { self.error = error } }
            })
        } catch { self.error = "Не удалось запустить локальный MCP-сервер." }
    }
    private func stopTransport() { listenerID = UUID(); server.stop(); listening = false; cancelJobs() }
    func stop() { stopTransport(); configuration = MCPConfiguration(); error = nil }
    func cancelJobs() {
        epoch = UUID(); dismissReview()
        for job in jobs { if job.active { job.status = "cancelled" }; job.expiry?.cancel(); job.task?.cancel(); job.cancel?(); job.action = nil; job.cancel = nil; job.result = nil }
        jobs.removeAll()
    }
    private func requireProfile(_ arguments: [String: Any]) throws -> AliasStore {
        guard available, let store, arguments["profile_id"] as? String == store.profiles.active.uuidString.lowercased() else { throw MCPFailure.message("Workspace or active profile changed. Call workspace_status again.") }
        return store
    }
    static func recordID(_ entry: SSHAlias) -> String {
        entry.localID?.uuidString.lowercased() ?? SHA256.hash(data: Data(entry.favoriteID.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func entry(_ arguments: [String: Any]) throws -> (AliasStore, SSHAlias) {
        let store = try requireProfile(arguments)
        guard let id = arguments["record_id"] as? String, let entry = store.profileEntries.first(where: { !$0.isQuickConnection && Self.recordID($0) == id }) else { throw MCPFailure.message("Record not found in the active profile.") }
        return (store, entry)
    }
    private func metadata(_ entry: SSHAlias, store: AliasStore) -> [String: Any] {
        var value: [String: Any] = ["record_id": Self.recordID(entry), "title": store.title(entry), "kind": (entry.recordKind ?? .ssh).rawValue, "host": entry.host, "user": entry.user, "port": entry.port, "group": store.group(entry), "can_ssh": entry.canSSH]
        if let text = entry.website, var url = URLComponents(string: text), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
            url.user = nil; url.password = nil; url.query = nil; url.fragment = nil; value["url"] = url.string ?? ""
        }
        return value
    }
    private func fields(_ value: InventoryFields) -> [String: String] { Dictionary(uniqueKeysWithValues: value.populated.map { ($0.rawValue, value[$0]) }) }
    private func inventory(_ entry: SSHAlias) throws -> [String: Any] {
        let record = try InventoryRepository().load(entry.favoriteID)
        var result: [String: Any] = ["record_id": Self.recordID(entry), "fields": fields(record.fields), "has_draft": record.draft != nil, "expected_revision": try MCPProtocol.hash(record), "field_definitions": InventoryField.allCases.map { ["key": $0.rawValue, "title": $0.title] }]
        if let snapshot = record.snapshots.last { result["collected"] = ["collector": snapshot.collector.rawValue, "date": ISO8601DateFormatter().string(from: snapshot.date), "facts": fields(snapshot.facts)] }
        return result
    }
    private func validateArguments(_ arguments: [String: Any], tool: [String: Any]) throws {
        let schema = tool["inputSchema"] as! [String: Any], properties = schema["properties"] as! [String: Any]
        guard Set(arguments.keys).isSubset(of: Set(properties.keys)), (schema["required"] as! [String]).allSatisfy({ arguments[$0] != nil }) else { throw MCPFailure.message("Missing or unknown tool arguments.") }
        for (key, value) in arguments {
            let rule = properties[key] as! [String: Any]
            switch rule["type"] as? String {
            case "string":
                guard let text = value as? String, text.utf8.count <= (key == "markdown" ? 50_000 : key == "command" ? 4096 : 2048), !text.contains("\0") else { throw MCPFailure.message("Invalid text argument: " + key) }
                if let choices = rule["enum"] as? [String], !choices.contains(text) { throw MCPFailure.message("Invalid choice: " + key) }
            case "integer":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue == Double(number.intValue), number.intValue >= (rule["minimum"] as? Int ?? 0), number.intValue <= (rule["maximum"] as? Int ?? 100_000) else { throw MCPFailure.message("Invalid number: " + key) }
            case "object":
                guard let pairs = value as? [String: String], pairs.count <= InventoryField.allCases.count, pairs.values.allSatisfy({ $0.utf8.count <= 16384 && !$0.contains("\0") }) else { throw MCPFailure.message("Invalid inventory fields.") }
            default: throw MCPFailure.message("Invalid argument schema.")
            }
        }
    }
    func handle(_ request: MCPHTTPRequest, listener: UUID? = nil) -> MCPHTTPResponse {
        guard !Task.isCancelled, listener == nil || listener == listenerID, available, configuration.enabled else { return .init(status: 503) }
        guard request.path == "/mcp" else { return .init(status: 404) }
        guard request.headers["origin"] == nil, ["127.0.0.1:\(configuration.port)", "localhost:\(configuration.port)"].contains(request.headers["host"]?.lowercased() ?? "") else { return .init(status: 403) }
        guard let authorization = request.headers["authorization"], authorization.hasPrefix("Bearer "), MCPProtocol.sameToken(String(authorization.dropFirst(7)), configuration.token) else { return .init(status: 401) }
        guard request.method == "POST" else { return .init(status: 405, headers: ["Allow": "POST"]) }
        guard request.headers["content-type"]?.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else { return .init(status: 415) }
        let accept = request.headers["accept"] ?? ""
        guard accept.contains("application/json") else { return .init(status: 406) }
        if Date().timeIntervalSince(rateStart) > 60 { rateStart = Date(); requestCount = 0 }
        requestCount += 1; guard requestCount <= 240 else { return .init(status: 429) }
        guard request.body.count <= MCPHTTPServer.maximumBody, let object = try? JSONSerialization.jsonObject(with: request.body), let rpc = object as? [String: Any], rpc["jsonrpc"] as? String == "2.0", let method = rpc["method"] as? String else { return MCPProtocol.error(code: -32600, message: "Invalid JSON-RPC request") }
        let id = rpc["id"]
        if let id, !(id is String) {
            guard let number = id as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue == number.doubleValue.rounded() else { return MCPProtocol.error(code: -32600, message: "Invalid request id") }
        }
        guard rpc["params"] == nil || rpc["params"] is [String: Any] else { return MCPProtocol.error(id, code: -32602, message: "Invalid params") }
        let params = rpc["params"] as? [String: Any] ?? [:], version = request.headers["mcp-protocol-version"]
        if let version, !MCPProtocol.versions.contains(version) { return MCPProtocol.error(id, code: -32022, message: "Unsupported protocol version", data: ["supported": MCPProtocol.versions, "requested": version]) }
        let modern = version == MCPProtocol.modern
        if modern {
            guard let meta = params["_meta"] as? [String: Any], meta["io.modelcontextprotocol/protocolVersion"] as? String == version, meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else { return MCPProtocol.error(id, code: -32602, message: "Protocol metadata is required") }
            guard request.headers["mcp-method"] == method, method != "tools/call" || MCPProtocol.decodedHeader(request.headers["mcp-name"]) == params["name"] as? String else { return MCPProtocol.error(id, code: -32020, message: "HTTP headers do not match the request") }
        }
        guard let id else {
            // Notifications never invoke tools, even if they contain tool arguments.
            guard method.hasPrefix("notifications/") else { return MCPProtocol.error(code: -32600, message: "A request id is required") }
            return .init(status: 202)
        }
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            let negotiated = MCPProtocol.versions.dropFirst().contains(requested) ? requested : "2025-11-25"
            return MCPProtocol.success(id, ["protocolVersion": negotiated, "capabilities": ["tools": ["listChanged": false]], "serverInfo": MCPProtocol.serverInfo, "instructions": MCPProtocol.instructions], modern: modern)
        case "server/discover": return MCPProtocol.success(id, ["supportedVersions": MCPProtocol.versions, "capabilities": ["tools": [:]], "instructions": MCPProtocol.instructions, "serverInfo": MCPProtocol.serverInfo], modern: modern)
        case "ping": return MCPProtocol.success(id, [:], modern: modern)
        case "tools/list":
            guard params["cursor"] == nil else { return MCPProtocol.error(id, code: -32602, message: "Unexpected cursor") }
            return MCPProtocol.success(id, ["tools": MCPProtocol.tools(configuration.permissions)], modern: modern)
        case "tools/call":
            guard let name = params["name"] as? String, let tool = MCPProtocol.tools(configuration.permissions).first(where: { $0["name"] as? String == name }), params["arguments"] == nil || params["arguments"] is [String: Any] else { return MCPProtocol.error(id, code: -32602, message: "Unknown or disabled tool, or invalid arguments") }
            do {
                let arguments = params["arguments"] as? [String: Any] ?? [:]; try validateArguments(arguments, tool: tool)
                return MCPProtocol.success(id, MCPProtocol.toolResult(try call(name, arguments)), modern: modern)
            } catch {
                if !(error is MCPFailure) { self.error = "Не удалось выполнить запрос MCP: " + error.localizedDescription }
                let message = (error as? MCPFailure)?.localizedDescription ?? "Operation failed. Review the request and current data in SSH Hub."
                return MCPProtocol.success(id, MCPProtocol.toolResult(["error": message], error: true), modern: modern)
            }
        default: return MCPProtocol.error(id, code: -32601, message: "Method not found", status: modern ? 404 : 200)
        }
    }
    private func call(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        guard available, let store else { throw MCPFailure.message("Database is locked.") }
        switch name {
        case "workspace_status": return ["profile_id": store.profiles.active.uuidString.lowercased(), "profile_name": store.profileName, "record_count": store.profileEntries.filter { !$0.isQuickConnection }.count, "permissions": ["create_records": configuration.permissions.createRecords, "write_documentation": configuration.permissions.writeDocumentation, "write_inventory": configuration.permissions.writeInventory, "execute_ssh": configuration.permissions.executeSSH]]
        case "records_list":
            let store = try requireProfile(arguments), query = arguments["query"] as? String ?? ""
            let entries = store.profileEntries.filter { !$0.isQuickConnection && (query.isEmpty || [store.title($0), $0.host, $0.user, store.group($0)].joined(separator: " ").localizedCaseInsensitiveContains(query)) }
            let offset = min(arguments["offset"] as? Int ?? 0, entries.count), limit = arguments["limit"] as? Int ?? 50
            let end = min(offset + limit, entries.count)
            return ["profile_id": store.profiles.active.uuidString.lowercased(), "total": entries.count, "records": entries[offset..<end].map { metadata($0, store: store) }, "next_offset": end < entries.count ? end as Any : NSNull()]
        case "records_get": let (store, entry) = try entry(arguments); return metadata(entry, store: store)
        case "documentation_get":
            let (_, entry) = try entry(arguments), doc = try DocumentationRepository().load(entry.favoriteID)
            return ["record_id": Self.recordID(entry), "markdown": doc.text, "has_draft": doc.hasChanges, "expected_revision": try MCPProtocol.hash(doc)]
        case "inventory_get": let (_, entry) = try entry(arguments); return try inventory(entry)
        case "jobs_get", "jobs_cancel":
            guard let id = arguments["job_id"] as? String, let job = jobs.first(where: { $0.id.uuidString.lowercased() == id && $0.profile == store.profiles.active && $0.epoch == epoch }) else { throw MCPFailure.message("Job not found in this workspace.") }
            if name == "jobs_cancel" { cancel(job.id) }; return job.response
        default: return try enqueue(name, arguments)
        }
    }
    private func enqueue(_ name: String, _ arguments: [String: Any]) throws -> [String: Any] {
        let store = try requireProfile(arguments)
        guard jobs.filter(\.active).count < 10 else { throw MCPFailure.message("Too many pending jobs. Review or cancel existing requests first.") }
        var preview = "", action: (@MainActor () async throws -> [String: Any])!
        var cancellation: (() -> Void)?
        if name == "records_create" {
            var record = LocalConnectionRecord(); record.title = arguments["title"] as! String; record.kind = RecordKind(rawValue: arguments["kind"] as! String)!
            record.host = arguments["host"] as? String ?? ""; record.user = arguments["user"] as? String ?? ""; record.port = (arguments["port"] as? Int).map(String.init) ?? record.kind.defaultPort
            record.website = arguments["url"] as? String ?? ""
            let group = arguments["group"] as? String ?? ""
            guard record.validation == nil, group.isEmpty || ConnectionTree.validPath(group) else { throw MCPFailure.message("Invalid record fields. SSH records require host and user; web records require a full HTTP(S) URL.") }
            let expected = try store.localRepository.load(), saved = record
            preview = "Создать запись · \(record.kind.rawValue)\n\(record.title)\n\(record.user)@\(record.host):\(record.port)\n\(record.website)\nГруппа: \(group)"
            action = { [weak store] in
                guard let store else { throw VaultError.locked }
                try store.commitRecord(saved, expected: expected, appearance: ConnectionAppearance(name: saved.title), group: group, ssh: nil, template: nil)
                return ["record_id": saved.id.uuidString.lowercased(), "created": true]
            }
        } else {
            let (_, entry) = try entry(arguments), fingerprint = MaintenancePlan.fingerprint(entry)
            let assertCurrent = { [weak store] in
                guard let store, let current = store.profileEntries.first(where: { $0.favoriteID == entry.favoriteID }), MaintenancePlan.fingerprint(current) == fingerprint else { throw MCPFailure.message("Record changed after review. Submit a new request.") }
            }
            let destination = "\(store.title(entry)) · \(entry.user)@\(entry.host):\(entry.port)"
            switch name {
            case "documentation_write":
                let doc = try DocumentationRepository().load(entry.favoriteID), text = arguments["markdown"] as! String, append = arguments["mode"] as! String == "append"
                guard try MCPProtocol.hash(doc) == arguments["expected_revision"] as? String else { throw MCPFailure.message("Documentation revision changed. Read it again.") }
                _ = try AssistantDocumentationChange.merged(original: doc, proposed: text, append: append)
                preview = "Документация · \(destination)\n\(append ? "Дополнить" : "Заменить")\n\n\(text)"
                action = { [weak store] in
                    try assertCurrent(); guard let store else { throw VaultError.locked }
                    try store.documentation.applyAssistant(text, append: append, expected: doc, key: entry.favoriteID)
                    return ["saved": true, "expected_revision": try MCPProtocol.hash(DocumentationRepository().load(entry.favoriteID))]
                }
            case "inventory_write":
                let original = try InventoryRepository().load(entry.favoriteID), changes = arguments["fields"] as! [String: String]
                guard try MCPProtocol.hash(original) == arguments["expected_revision"] as? String, original.draft == nil else { throw MCPFailure.message("Inventory changed or has an unsaved draft. Save it in SSH Hub and read it again.") }
                guard !changes.isEmpty, changes.keys.allSatisfy({ InventoryField(rawValue: $0) != nil }) else { throw MCPFailure.message("Use known inventory field keys from inventory_get.") }
                var updated = original, fields = original.fields
                for (key, value) in changes { fields[InventoryField(rawValue: key)!] = value }
                updated.draft = fields; updated.save(); try InventoryRepository.validate(updated)
                let saved = updated
                preview = "Инвентаризация · \(destination)\n\n" + changes.keys.sorted().map { "\(InventoryField(rawValue: $0)!.title): \(changes[$0]!)" }.joined(separator: "\n")
                action = { [weak store] in
                    try assertCurrent(); guard try InventoryRepository().load(entry.favoriteID) == original else { throw MCPFailure.message("Inventory changed after review.") }
                    try InventoryRepository().write(saved, for: entry.favoriteID)
                    store?.inventoryModels.values.filter { $0.key == entry.favoriteID }.forEach { $0.reload() }
                    return ["saved": true, "expected_revision": try MCPProtocol.hash(saved)]
                }
            case "ssh_run":
                guard entry.canSSH, !entry.isQuickConnection else { throw MCPFailure.message("Only saved SSH records support remote commands.") }
                let command = arguments["command"] as! String, timeout = arguments["timeout_seconds"] as? Int ?? 30
                let workflow = MaintenanceWorkflow(name: "Команда MCP", steps: [MaintenanceStep(title: "Команда MCP", command: command, timeout: timeout)])
                let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: store.config.url)
                let plan = try MaintenancePlan(workflow: workflow, entries: [(prepared, store.title(entry))], config: store.config.url)
                let runner = MaintenanceModel(config: store.config.url, profile: store.profiles.active, runStep: runStep)
                let target = plan.targets[0].entry
                preview = "SSH · \(store.title(entry)) · \(target.user)@\(target.host):\(target.port)\nТаймаут: \(timeout) с\n\n" + plan.targets[0].steps[0].command
                cancellation = { runner.stop() }
                action = { [weak store] in
                    try assertCurrent(); guard let store else { throw VaultError.locked }
                    runner.run(plan, current: store.profileEntries, config: store.config.url)
                    while runner.busy { try await Task.sleep(for: .milliseconds(30)) }
                    try Task.checkCancellation()
                    guard runner.error == nil, let result = runner.results.last else { throw MCPFailure.message("SSH execution failed. Review the connection in SSH Hub.") }
                    return ["output": AssistantDiagnosticReport.clean(result.output, limit: 65_536), "status": result.status, "success": result.passed, "output_truncated": result.output.count > 65_536]
                }
            case "inventory_collect":
                guard entry.canSSH, !entry.isQuickConnection else { throw MCPFailure.message("Only saved SSH records support collection.") }
                let model = InventoryModel(entry: entry, config: store.config.url); model.collector = InventoryCollector(rawValue: arguments["collector"] as! String)!
                let collector = model.collector
                let prepared = try SSHPasswordStore.preparedEntry(for: entry, config: store.config.url)
                let preparedFingerprint = MaintenancePlan.fingerprint(prepared)
                preview = "Сбор инвентаризации · \(store.title(entry)) · \(prepared.user)@\(prepared.host):\(prepared.port)\n\(collector.title)\n\n" + InventoryCollection.command(collector)
                cancellation = { model.stop() }
                action = { [weak self, weak store] in
                    try assertCurrent(); guard let store, MaintenancePlan.fingerprint(try SSHPasswordStore.preparedEntry(for: entry, config: store.config.url)) == preparedFingerprint else { throw MCPFailure.message("SSH credentials changed after review.") }; model.collect()
                    while model.busy { try await Task.sleep(for: .milliseconds(30)) }
                    try Task.checkCancellation()
                    guard model.error == nil, let self else { throw MCPFailure.message("Collection failed. Review the connection in SSH Hub.") }
                    return try self.inventory(entry)
                }
            default: throw MCPFailure.message("Unknown tool.")
            }
        }
        let job = MCPJob(name: name, preview: preview, profile: store.profiles.active, epoch: epoch, action: action); job.cancel = cancellation
        // Retain only bounded in-memory results; they are erased on lock, rotation and profile change.
        while jobs.count >= 20, let index = jobs.firstIndex(where: { !$0.active }) { jobs.remove(at: index) }
        jobs.append(job)
        job.expiry = Task { [weak self, weak job] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled, let self, let job, job.status == "pending_approval" else { return }; self.cancel(job.id, status: "expired")
        }
        if presentReviews { showNextReview() }
        return job.response
    }
    func approve(_ id: UUID) {
        guard available, configuration.enabled, let store, let job = jobs.first(where: { $0.id == id && $0.status == "pending_approval" && $0.epoch == epoch && $0.profile == store.profiles.active }), MCPProtocol.tools(configuration.permissions).contains(where: { $0["name"] as? String == job.name }), let action = job.action else { return }
        job.expiry?.cancel(); job.action = nil; job.status = "running"; dismissReview(); objectWillChange.send()
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            defer { job.cancel = nil; job.task = nil; self.objectWillChange.send(); if self.presentReviews { self.showNextReview() } }
            do {
                try Task.checkCancellation(); let result = try await action(); try Task.checkCancellation()
                guard self.available, self.epoch == job.epoch, self.store?.profiles.active == job.profile, job.status == "running" else { return }
                job.result = result; job.status = "completed"
            } catch {
                guard self.epoch == job.epoch, job.status == "running" else { return }
                job.status = Task.isCancelled ? "cancelled" : "failed"
                job.result = ["error": (error as? MCPFailure)?.localizedDescription ?? "Operation failed. Review current data and connection in SSH Hub."]
            }
        }
    }
    func cancel(_ id: UUID, status: String = "cancelled") {
        guard let job = jobs.first(where: { $0.id == id }), job.active else { return }
        job.status = status; job.expiry?.cancel(); job.task?.cancel(); job.cancel?(); job.action = nil
        if reviewWindow?.jobID == id { dismissReview() }
        objectWillChange.send(); if presentReviews { showNextReview() }
    }
    func review(_ id: UUID) {
        guard presentReviews, reviewWindow == nil, let job = jobs.first(where: { $0.id == id && $0.status == "pending_approval" }) else { return }
        let window = MCPReviewWindow(model: self, job: job); reviewWindow = window; window.showWindow(nil); window.window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func showNextReview() {
        guard available, reviewWindow == nil, !jobs.contains(where: { $0.status == "running" }), let job = jobs.first(where: { $0.status == "pending_approval" }) else { return }; review(job.id)
    }
    private func dismissReview() { let window = reviewWindow; reviewWindow = nil; window?.window?.delegate = nil; window?.window?.contentView = nil; window?.close() }
}

extension AliasStore {
    func mcpController() -> MCPController {
        if let mcp { return mcp }
        let value = MCPController(store: self); mcp = value; return value
    }
}
