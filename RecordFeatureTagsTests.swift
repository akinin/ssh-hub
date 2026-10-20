import Foundation
@main enum RecordFeatureTagsTests {
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func main() throws {
        func detect(_ doc: ConnectionDocument = ConnectionDocument(), _ files: [ConnectionAttachment] = [], _ inventory: RecordInventory = RecordInventory(), _ notifications: Bool = false) -> [RecordFeatureTag] { RecordFeatureTag.detect(document: doc, attachments: files, inventory: inventory, notifications: notifications) }
        check(detect().isEmpty, "empty record")
        var doc = ConnectionDocument(); doc.markdown = "  \n "; check(detect(doc).isEmpty, "whitespace ignored")
        doc.draft = "Draft note"; check(detect(doc) == [.documentation], "durable draft counts")
        doc.draft = ""; check(detect(doc).isEmpty, "cleared draft removes tag")
        let attachment = ConnectionAttachment(name: "Owned.txt", size: 1)
        check(detect(ConnectionDocument(), [attachment]) == [.attachments], "attachment")
        var removed = attachment; removed.removed = true; check(detect(ConnectionDocument(), [removed]).isEmpty, "removed attachment")
        var inventory = RecordInventory(); inventory.manual[.processor] = "Owned CPU"
        check(detect(ConnectionDocument(), [], inventory) == [.inventory], "partially filled inventory")
        inventory.draft = InventoryFields(); check(detect(ConnectionDocument(), [], inventory).isEmpty, "cleared draft overrides old manual")
        inventory = RecordInventory(); inventory.manual[.email] = "legacy hidden contact"
        check(detect(ConnectionDocument(), [], inventory).isEmpty, "retired contact does not create badge")
        check(detect(ConnectionDocument(), [], RecordInventory(), true) == [.notifications], "confirmed notification")
        let receipt = LoginNotificationReceipt(fingerprint: "old", checked: Date(), configured: true)
        check(receipt.matches("old") && !receipt.matches("new"), "old endpoint receipt cannot apply to new server")
        check(!LoginNotificationReceipt(fingerprint: "old", checked: Date(), configured: false).matches("old"), "removed notification")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-hub-material-tags-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = DocumentationRepository(root: root), key = "owned"
        let changes = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(forName: Notification.Name("SSHHubRecordMaterialsChanged"), object: nil, queue: nil) { note in if note.userInfo?["key"] as? String == key { changes.count += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        doc = ConnectionDocument(); doc.markdown = "Saved note"; try repository.write(doc, for: key)
        check(detect(try repository.load(key)) == [.documentation] && changes.count == 1, "write publishes change")
        try repository.write(ConnectionDocument(), for: key)
        check(detect(try repository.load(key)).isEmpty && changes.count == 2, "removal publishes change")
        print("Automatic record material tag tests passed")
    }
}
private final class NotificationCounter: @unchecked Sendable { var count = 0 }
