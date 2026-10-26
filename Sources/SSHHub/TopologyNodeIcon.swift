import SwiftUI
import AppKit

struct TopologyProviderLogo: View {
    let identity: TopologyProviderIdentity
    var size: CGFloat = 28
    var body: some View {
        Group {
            if let data = identity.iconPNG, TopologyProviderIdentity.validIconPNG(data), let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFit().padding(2)
                    .background(.white, in: RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: "globe").resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }.frame(width: size, height: size).accessibilityLabel(identity.organization.isEmpty ? identity.asn : identity.organization)
    }
}

struct TopologyNodeIcon: View {
    let node: TopologyNode
    var size: CGFloat = 25
    var selected = false
    var body: some View {
        if node.displayKind == .internet, let identity = node.providerIdentities.filter({ $0.iconPNG != nil }).max(by: { $0.date < $1.date }) {
            TopologyProviderLogo(identity: identity, size: size)
        } else {
            Image(systemName: node.displayKind.icon).font(.system(size: size))
                .foregroundStyle(selected ? Color.accentColor : .secondary).frame(width: size + 7)
        }
    }
}

struct TopologyPortsSummary: View {
    let node: TopologyNode
    var compact = false
    private var ports: [TopologyInterface] { Array((node.observed?.interfaces ?? []).prefix(compact ? 6 : 64)) }
    private var fresh: Bool {
        guard let facts = node.observed else { return false }
        return TopologyStatus.fresh(facts.interfacesAt ?? facts.collectedAt, now: Date())
    }
    var body: some View {
        if !ports.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                if !compact { Text("Порты").font(.subheadline).bold() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: compact ? 25 : 30), spacing: 5)], alignment: .leading, spacing: 6) {
                    ForEach(Array(ports.enumerated()), id: \.offset) { _, port in
                        VStack(spacing: 3) {
                            Text(port.name).font(.system(size: 9, weight: .medium)).lineLimit(1)
                            ZStack {
                                RoundedRectangle(cornerRadius: 3).fill(color(port)).frame(height: compact ? 16 : 22)
                                if port.poeEnabled == true { Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(.black.opacity(0.75)) }
                            }
                            Text(speed(port.speedMbps)).font(.system(size: 8)).foregroundStyle(.secondary).lineLimit(1)
                        }.help(port.name + " · " + TopologyFormat.speed(port.speedMbps) + (port.poeEnabled == true ? " · PoE включён" : ""))
                    }
                }
                if compact, (node.observed?.interfaces.count ?? 0) > ports.count { Text("Ещё \((node.observed?.interfaces.count ?? 0) - ports.count) портов в сведениях").font(.system(size: 8)).foregroundStyle(.secondary) }
                if !fresh { Text("Сведения портов устарели").font(.system(size: compact ? 8 : 10)).foregroundStyle(.secondary) }
                if !compact { Text("Цвет: оранжевый — FE, зелёный — от 1 Гбит/с, серый — нет актуального линка. Молния — PoE включён.").font(.caption2).foregroundStyle(.secondary) }
            }
        } else if !compact {
            Text("Порты появятся после обновления UniFi или SSH.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func color(_ port: TopologyInterface) -> Color {
        guard fresh, port.state?.uppercased() == "UP" else { return .secondary.opacity(0.3) }
        guard let speed = port.speedMbps, speed > 0 else { return .blue.opacity(0.6) }
        return speed < 1000 ? .orange : .green
    }
    private func speed(_ value: Double?) -> String {
        guard let value, value > 0 else { return "—" }
        if value < 1000 { return value == 100 ? "FE" : String(format: "%gM", value) }
        return value == 1000 ? "GbE" : String(format: "%gG", value / 1000)
    }
}
