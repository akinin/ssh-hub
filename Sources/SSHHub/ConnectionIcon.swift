import SwiftUI
import AppKit

struct ConnectionIcon: View {
    let appearance: ConnectionAppearance
    var size: CGFloat = 24
    var symbol: String = "server.rack"
    var body: some View {
        Group {
            if let data = appearance.logo, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
            } else {
                Image(systemName: symbol).resizable().scaledToFit().padding(size * 0.12).foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.18))
    }
}
