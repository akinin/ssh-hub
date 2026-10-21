import SwiftUI
import AppKit

enum InterfaceDensity: String, CaseIterable, Identifiable {
    case normal, compact
    static let key = "interfaceDensity.v1"
    var id: String { rawValue }
    var title: String { self == .normal ? "Обычный" : "Компактный" }
    var rowHeight: CGFloat { self == .normal ? 28 : 21 }
    var tileHeight: CGFloat { self == .normal ? 76 : 56 }
}

struct HubSheetHeader: View {
    let title: String
    let subtitle: String
    let icon: String
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon).font(.system(size: 21, weight: .medium)).foregroundStyle(.tint)
                .frame(width: 40, height: 40).background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(.primary)
                if !subtitle.isEmpty { Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HubSidebarItem: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 22)
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(height: 36)
                .foregroundStyle(selected ? Color.white : .primary)
                .background(selected ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 7))
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).help(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct HubNotice: View {
    let text: String
    var icon = "info.circle"
    var tint = Color.secondary
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 16).padding(.top, 1)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(10).background(tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct RecordActionTile: View {
    let title: String
    let detail: String
    let icon: String
    let color: Color
    var primary = false
    var density = InterfaceDensity.normal
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: density == .compact ? 19 : 22, weight: primary ? .medium : .regular)).foregroundStyle(color).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: primary ? .bold : .medium)).foregroundStyle(.primary).lineLimit(2)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.padding(.horizontal, 14).frame(maxWidth: .infinity, alignment: .leading).frame(height: density.tileHeight)
                .background(primary ? color.opacity(hovering ? 0.24 : 0.16) : Color.primary.opacity(hovering ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(primary ? color.opacity(hovering ? 0.65 : 0.4) : Color.primary.opacity(hovering ? 0.15 : 0.06), lineWidth: 1) }
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).onHover { hovering = $0 }.help(title + " · " + detail)
            .opacity(enabled ? 1 : 0.45).accessibilityLabel(title + ", " + detail)
    }
}


struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right").font(.caption.weight(.semibold)).frame(width: 12)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityValue(configuration.isExpanded ? "Развёрнуто" : "Свёрнуто")
            if configuration.isExpanded { configuration.content }
        }
    }
}
