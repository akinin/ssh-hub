import Foundation

@main struct TabInformationTests {
    static func main() {
        let info = TabInformation(title: "Сервер", kind: "SSH", host: "device.example", user: "tester", port: "2222", profile: "Work", state: "Подключено")
        precondition(info.tooltip == "Сервер — SSH\nАдрес: device.example · порт 2222\nПользователь: tester\nПрофиль: Work\nСостояние: Подключено")
        precondition(!TabInformation(title: "Локальный", kind: "Консоль").tooltip.contains("Адрес:"))
        precondition(TabInformation.clean("first\nsecond\u{0000}") == "firstsecond")
        precondition(TabInformation.clean(String(repeating: "я", count: 1000)).count == 240)
        print("Tab information tests passed: connection metadata, empty fields, control characters and bounded labels")
    }
}
