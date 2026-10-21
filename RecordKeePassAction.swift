import SwiftUI

struct RecordKeePassAction: View {
    let entry: SSHAlias
    let copy: KDBXRecordCopy?
    let style: RecordActionStyle
    let density: InterfaceDensity
    var header = false
    @ObservedObject var vault: SharedCredentialVault
    @ObservedObject var workspace: KDBXWorkspace
    let onTap: () -> Void
    private var reference: KDBXReference? { vault.document.preset(for: entry.favoriteID)?.kdbx ?? copy?.reference }
    private var state: KDBXRecordState {
        KDBXRecordState.resolve(reference: reference, databases: vault.document.kdbxDatabases ?? [], catalog: reference.flatMap { workspace.runtime.catalog($0.databaseID) }, changed: vault.document.preset(for: entry.favoriteID)?.kdbx == nil && copy.map { $0.fingerprint != KDBXRecordCopy.fingerprint(entry) } == true)
    }
    private var statusColor: Color { switch state { case .available: return .green; case .unlinked: return .secondary; case .locked, .expired, .changed: return .orange; case .databaseMissing, .missing: return .red } }
    var body: some View {
        Group {
            if header {
                Button(action: onTap) {
                    HStack(spacing: 5) { Image(systemName: "key").foregroundStyle(statusColor); Circle().fill(statusColor).frame(width: 5, height: 5); Text("KeePass").font(.caption.weight(.medium)).foregroundStyle(statusColor) }.padding(.horizontal, 8).frame(height: 28)
                }.buttonStyle(.plain).background(statusColor.opacity(0.13), in: Capsule()).overlay { Capsule().strokeBorder(statusColor.opacity(0.4)) }.fixedSize()
            } else {
                RecordActionTile(title: "KeePass", detail: state.title, icon: "key", color: style.tint, density: density, action: onTap)
                    .overlay(alignment: .topTrailing) { Circle().fill(statusColor).frame(width: 7, height: 7).padding(10).allowsHitTesting(false) }
            }
        }.help("KeePass: " + state.title + "\n" + state.detail).accessibilityLabel("KeePass: " + state.title + ". " + state.detail)
    }
}
