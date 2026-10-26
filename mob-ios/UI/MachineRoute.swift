import SwiftUI

/// A machine's subtitle: "● LAN · office-mac.local", or, when the address in use does not answer
/// (or needs pairing) and there is another, "○ LAN not reachable · Use Remote". The app never switches by itself.
struct RouteLine: View {
    @Environment(AppState.self) private var app
    let machine: Machine

    var body: some View {
        let up = app.reachable(machine)
        HStack(spacing: 5) {
            Circle().fill(up == true ? Color.success : up == false ? Color.red : Color.secondary.opacity(0.5)).frame(width: 7, height: 7)
            if let a = machine.address {
                if up == false || machine.needsPairing, let other = machine.addresses.first(where: { $0.id != a.id }) {
                    Text("\(machine.label(a)) \(machine.needsPairing ? "needs pairing" : "not reachable") ·")
                    Button("Use \(machine.label(other))") {
                        app.selectRoute(machine.id, other.id)
                        app.selectMachine(machine.id)
                    }
                    .buttonStyle(.borderless).font(.caption.weight(.semibold))
                } else if machine.addresses.count > 1 {
                    Text("\(machine.label(a)) · \(Machine.host(a.url))")
                } else {
                    Text(a.url)
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
    }
}

/// "Use LAN ✓" / "Use Remote" for a machine with more than one address. In a route submenu
/// (`short`) the items are just "LAN ✓" / "Remote", with the host under each.
struct RouteMenuItems: View {
    @Environment(AppState.self) private var app
    let machine: Machine
    var short = false

    var body: some View {
        if machine.addresses.count > 1 {
            ForEach(machine.addresses) { a in
                Button {
                    app.selectRoute(machine.id, a.id)
                    app.selectMachine(machine.id)
                } label: {
                    let title = short ? machine.label(a) : "Use \(machine.label(a))"
                    if a.id == machine.address?.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                    if short { Text(Machine.host(a.url)) }
                }
            }
        }
    }
}

/// Above the chat: the address in use does not answer (or needs pairing) and the machine has
/// another, e.g. after leaving the office with a chat open. One tap switches.
struct RouteBanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if let m = app.activeMachine, let a = m.address, app.reachable(m) == false || m.needsPairing,
           let other = m.addresses.first(where: { $0.id != a.id }) {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark").foregroundStyle(Color.waiting)
                Text("\(m.label(a)) \(m.needsPairing ? "needs pairing" : "not reachable")").font(.subheadline)
                Spacer()
                Button("Use \(m.label(other))") { app.selectRoute(m.id, other.id) }
                    .buttonStyle(.bordered).controlSize(.small)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
