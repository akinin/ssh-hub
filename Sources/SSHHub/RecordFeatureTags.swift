import Foundation

// Derived public metadata, never copied into user-entered tags or record exports.
enum RecordFeatureTag: String, CaseIterable, Identifiable {
    case notifications, documentation, attachments, inventory
    var id: String { rawValue }
    var title: String { switch self { case .notifications: return "Уведомления"; case .documentation: return "Документация"; case .attachments: return "Вложения"; case .inventory: return "Инвентаризация" } }
    var icon: String { switch self { case .notifications: return "bell.badge"; case .documentation: return "doc.text"; case .attachments: return "paperclip"; case .inventory: return "shippingbox" } }
    static func detect(document: ConnectionDocument, attachments: [ConnectionAttachment], inventory: RecordInventory, notifications: Bool) -> [Self] {
        var result: [Self] = []
        if notifications { result.append(.notifications) }
        if !document.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(.documentation) }
        if attachments.contains(where: { !$0.removed }) { result.append(.attachments) }
        if InventorySection.allCases.flatMap(\.fields).contains(where: { !inventory.fields[$0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { result.append(.inventory) }
        return result
    }
}
struct LoginNotificationReceipt: Codable {
    var fingerprint: String
    var checked: Date
    var configured: Bool
    func matches(_ fingerprint: String) -> Bool { self.fingerprint == fingerprint && configured }
}
