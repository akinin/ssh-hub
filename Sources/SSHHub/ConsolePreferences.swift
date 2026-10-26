import SwiftUI
import AppKit
import SwiftTerm

@MainActor final class ConsolePreferences: ObservableObject {
    static let shared = ConsolePreferences()
    @Published var fontName: String { didSet { persist() } }
    @Published var fontSize: Double { didSet { persist() } }
    @Published var foreground: String { didSet { persist() } }
    @Published var background: String { didSet { persist() } }
    init() {
        let defaults = UserDefaults.standard
        fontName = defaults.string(forKey: "console.font.v1") ?? "Menlo"
        fontSize = min(32, max(8, defaults.object(forKey: "console.fontSize.v1") as? Double ?? 12))
        foreground = defaults.string(forKey: "console.foreground.v1") ?? "E0E6ED"
        background = defaults.string(forKey: "console.background.v1") ?? "0E1115"
    }
    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(fontName, forKey: "console.font.v1"); defaults.set(fontSize, forKey: "console.fontSize.v1")
        defaults.set(foreground, forKey: "console.foreground.v1"); defaults.set(background, forKey: "console.background.v1")
    }
    static func color(_ hex: String) -> NSColor {
        let value = UInt32(hex, radix: 16) ?? 0
        return NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1)
    }
    static func hex(_ color: SwiftUI.Color) -> String {
        guard let value = NSColor(color).usingColorSpace(.sRGB) else { return "FFFFFF" }
        return String(format: "%02X%02X%02X", Int(value.redComponent * 255), Int(value.greenComponent * 255), Int(value.blueComponent * 255))
    }
    func apply(to terminal: LocalProcessTerminalView, zoom: Double) {
        let size = min(64, max(6, fontSize * zoom))
        terminal.font = NSFont(name: fontName, size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        terminal.nativeForegroundColor = Self.color(foreground); terminal.nativeBackgroundColor = Self.color(background)
        terminal.superview?.layer?.backgroundColor = terminal.nativeBackgroundColor.cgColor
    }
}
struct ConsolePreferencesView: View {
    @ObservedObject private var preferences = ConsolePreferences.shared
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 14) {
            GridRow {
                Text("Шрифт")
                Picker("Шрифт", selection: $preferences.fontName) {
                    ForEach(Array(Set(["Menlo", "Monaco", "SFMono-Regular", preferences.fontName])).sorted(), id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 210, alignment: .leading)
            }
            GridRow {
                Text("Размер \(Int(preferences.fontSize))").monospacedDigit()
                Slider(value: $preferences.fontSize, in: 8...32, step: 1)
                    .labelsHidden().frame(width: 210).accessibilityLabel("Размер шрифта")
            }
            GridRow {
                Text("Текст")
                ColorPicker("Цвет текста", selection: Binding(get: { Color(nsColor: ConsolePreferences.color(preferences.foreground)) }, set: { preferences.foreground = ConsolePreferences.hex($0) }), supportsOpacity: false)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Text("Фон")
                ColorPicker("Цвет фона", selection: Binding(get: { Color(nsColor: ConsolePreferences.color(preferences.background)) }, set: { preferences.background = ConsolePreferences.hex($0) }), supportsOpacity: false)
                    .labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            GridRow {
                Text("Схема")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { schemes }
                    VStack(alignment: .leading, spacing: 8) { schemes }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
    @ViewBuilder private var schemes: some View {
        Button("Тёмная") { preferences.foreground = "E0E6ED"; preferences.background = "0E1115" }
        Button("Светлая") { preferences.foreground = "20252A"; preferences.background = "FAFAFA" }
        Button("Зелёная") { preferences.foreground = "83E48C"; preferences.background = "08120D" }
    }
}
