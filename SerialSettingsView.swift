import SwiftUI

struct SerialSettingsFields: View {
    @Binding var settings: SerialSettings
    @State private var devices = SerialSettings.devices
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Устройство", text: $settings.device, prompt: Text("/dev/cu.usbserial-…")).textFieldStyle(.roundedBorder).accessibilityIdentifier("serialDevice")
                Menu {
                    if devices.isEmpty { Text("Устройства не найдены") }
                    ForEach(devices, id: \.self) { path in Button(path) { settings.device = path } }
                } label: { Image(systemName: "cable.connector") }.menuStyle(.borderlessButton).frame(width: 25).help("Доступные serial-порты")
                Button { devices = SerialSettings.devices } label: { Image(systemName: "arrow.clockwise") }.help("Обновить порты")
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
                GridRow {
                    Text("Скорость")
                    Picker("Скорость", selection: $settings.baud) { ForEach(SerialSettings.speeds, id: \.self) { Text(String($0)).tag($0) } }.labelsHidden()
                }
                GridRow { Text("Биты данных"); Picker("Биты данных", selection: $settings.dataBits) { Text("7").tag(7); Text("8").tag(8) }.labelsHidden() }
                GridRow { Text("Чётность"); Picker("Чётность", selection: $settings.parity) { Text("Нет").tag("none"); Text("Even").tag("even"); Text("Odd").tag("odd") }.labelsHidden() }
                GridRow { Text("Стоп-биты"); Picker("Стоп-биты", selection: $settings.stopBits) { Text("1").tag(1); Text("2").tag(2) }.labelsHidden() }
                GridRow { Text("Управление потоком"); Picker("Управление потоком", selection: $settings.flow) { Text("Нет").tag("none"); Text("RTS/CTS").tag("rtscts"); Text("XON/XOFF").tag("xonxoff") }.labelsHidden() }
            }
            Text("Подключение открывается во встроенной консоли. Порт может использовать только один сеанс одновременно.").font(.caption).foregroundStyle(.secondary)
        }
    }
}
