import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var editing: Machine?
    @State private var pairing: PairRequest?
    @State private var deleting: Machine?
    @State private var notificationsAllowed = true

    var body: some View {
        NavigationStack {
            Form {
                if app.activeMachine != nil { status }
                Section("Machines") {
                    if app.machines.isEmpty {
                        Text("No office Mac yet. Run mobd link on the Mac that runs the agent, then add it with the link or QR code.").foregroundStyle(.secondary)
                    }
                    ForEach(app.machines) { m in
                        HStack {
                            Button { app.selectMachine(m.id) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: m.id == app.activeMachineId ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(m.id == app.activeMachineId ? Color.accentColor : .secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(m.name).foregroundStyle(.primary)
                                        Text(m.mobdUrl + (m.vncUsername.isEmpty ? "" : " · sign-in as \(m.vncUsername)"))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        if m.needsPairing {
                                            Label("Needs pairing", systemImage: "exclamationmark.triangle.fill")
                                                .font(.caption).foregroundStyle(Color.waiting)
                                        }
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            if m.needsPairing {
                                Button("Pair again") { pairing = PairRequest(machine: m) }.buttonStyle(.borderless)
                            }
                            Button { editing = m } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).accessibilityLabel("Edit \(m.name)")
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { deleting = m }
                            Button("Pair again") { pairing = PairRequest(machine: m) }
                        }
                    }
                    Button { pairing = PairRequest(machine: nil) } label: { Label("Add machine", systemImage: "plus") }
                }
                Section {
                    if !notificationsAllowed {
                        Button("Turn on notifications") { openURL(URL(string: UIApplication.openNotificationSettingsURLString)!) }
                    }
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("mob notifies you when the agent asks something or a task finishes, on every office Mac in the list. While mob is open this is immediate. In the background iOS does not allow a live connection, so mob checks when iOS lets it refresh, usually every 15 minutes or more.")
                }
                Section {
                    NavigationLink("Log") { LogView() }
                } footer: {
                    Text("Connections, event streams, live view and errors, for troubleshooting.")
                }
                Section("About") {
                    LabeledContent("mob-ios", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    Text("MIT License").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .sheet(item: $editing) { m in
                MachineEditor(initial: m) { app.save($0, vncPassword: $1) }
            }
            .sheet(item: $pairing) { PairingSheet(existing: $0.machine) }
            .confirmationDialog("Remove \(deleting?.name ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let m = deleting { app.delete(m) } }
            } message: {
                Text("Only removes it from this phone. Chats stay on the office Mac.")
            }
            .task(id: phase) { notificationsAllowed = await app.notifier.allowed() }
        }
    }

    private var status: some View {
        Section("Status") {
            HStack(spacing: 8) {
                Circle().fill(app.isConnected ? Color.success : .red).frame(width: 10, height: 10)
                Text(app.isConnected ? "Connected to \(app.activeMachine?.name ?? "")" : "Not connected")
                    .foregroundStyle(app.isConnected ? Color.primary : .red)
            }
            if let e = app.healthError { Text(e).font(.caption).foregroundStyle(.red) }
            if let m = app.activeMachine, m.needsPairing {
                Text("mobd on \(m.name) does not accept this device. Run mobd link on the office Mac and pair again.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Pair again") { pairing = PairRequest(machine: m) }
            }
            if let h = app.health {
                let runners = (h.runners ?? []).map { $0.title + ($0.available == false ? " (unavailable)" : "") }.joined(separator: ", ")
                LabeledContent("Runners", value: runners.isEmpty ? (h.runner ?? "—") : runners)
                if !h.problems.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Needs attention on the office Mac").font(.subheadline.weight(.semibold)).foregroundStyle(Color.waiting)
                        ForEach(h.problems, id: \.label) { p in
                            Label {
                                VStack(alignment: .leading) {
                                    Text(p.label)
                                    if !p.detail.isEmpty { Text(p.detail).font(.caption).foregroundStyle(.secondary) }
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.waiting)
                            }
                        }
                    }
                }
            }
            Button("Test connection") { app.checkHealth() }
        }
    }
}

/// Which machine the pairing sheet is for; nil machine adds a new one.
struct PairRequest: Identifiable {
    let id = UUID()
    let machine: Machine?
}

/// Name and desktop sign-in of a paired machine; its address comes from pairing.
private struct MachineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var machine: Machine
    @State private var password: String
    @State private var quality: LiveQuality = .auto
    let onSave: (Machine, String) -> Void

    init(initial: Machine, onSave: @escaping (Machine, String) -> Void) {
        _machine = State(initialValue: initial)
        _password = State(initialValue: initial.vncPassword)
        _quality = State(initialValue: LiveQuality(rawValue: initial.liveQuality ?? "") ?? .auto)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (Office Mac)", text: $machine.name)
                    LabeledContent("Address", value: machine.mobdUrl)
                } footer: {
                    Text("The address comes from the pairing link. If the office Mac moved, use Pair again with a new link.")
                }
                Section {
                    TextField("Mac user name", text: $machine.vncUsername)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mac or VNC password", text: $password)
                } header: {
                    Text("Desktop sign-in (optional)")
                } footer: {
                    Text("With a user name the live view signs in as that user, like Screen Sharing.app. A Screen Sharing (VNC) password alone, with no user name, opens the login window. Stored in this phone's Keychain only; without either the desktop shows snapshots.")
                }
                Section {
                    Picker("Quality", selection: $quality) {
                        ForEach(LiveQuality.allCases) { q in
                            Text(q.label).tag(q)
                        }
                    }
                } header: {
                    Text("Live desktop quality")
                } footer: {
                    Text(quality.hint)
                }
            }
            .onChange(of: quality) { _, new in
                machine.liveQuality = new.rawValue
            }
            .navigationTitle("Edit machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var m = machine
                        m.name = m.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Office Mac" : m.name.trimmingCharacters(in: .whitespaces)
                        m.vncUsername = m.vncUsername.trimmingCharacters(in: .whitespaces)
                        onSave(m, password)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Pairs this device with an office Mac from the link or QR code printed by `mobd link`.
struct PairingSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    /// The machine to pair again; nil adds one (or pairs again the saved machine of that office).
    let existing: Machine?
    @State private var text = ""
    @State private var link: PairLink?
    @State private var linkError: String?
    @State private var deviceName = UIDevice.current.name
    @State private var officeName = ""
    @State private var confirmed = false
    @State private var busy = false
    @State private var error: String?
    @State private var scanning = false

    /// The saved machine this pairing replaces.
    private var target: Machine? {
        existing ?? link.flatMap { l in app.machines.first { $0.serverId == l.serverId } }
    }

    /// The link points somewhere other than the saved address.
    private var moved: Bool {
        guard let t = target, let link, !t.mobdUrl.isEmpty, let url = URL(string: link.origin) else { return false }
        return !sameOrigin(APIClient.normalize(t.mobdUrl), url)
    }

    /// The link belongs to another office than the one saved.
    private var otherOffice: Bool {
        guard let id = target?.serverId, let link else { return false }
        return id != link.serverId
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http(s)://…/pair#v=1&…", text: $text, axis: .vertical)
                        .lineLimit(1...4).font(.callout.monospaced())
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    HStack {
                        Button { if let s = UIPasteboard.general.string { text = s } } label: { Label("Paste", systemImage: "doc.on.clipboard") }
                        Spacer()
                        Button { scanning = true } label: { Label("Scan QR code", systemImage: "qrcode.viewfinder") }
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Pairing link")
                } footer: {
                    if let linkError { Text(linkError).foregroundStyle(.red) } else {
                        Text("On the office Mac run mobd link. It prints a QR code and a link; each works once.")
                    }
                }
                if let link { office(link) }
                Section {
                    TextField("Device name", text: $deviceName)
                } header: {
                    Text("This device")
                } footer: {
                    Text("Shown on the office Mac in the list of paired devices.")
                }
                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            Text(target == nil ? "Pair" : "Pair again")
                            if busy { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(link == nil || busy || ((moved || otherOffice) && !confirmed) || PairLink.validName(deviceName) == nil)
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                } footer: {
                    Text("mobd link prints the same kind of link for every way of reaching the office Mac: its LAN, VPN or Tailscale address, or a self-hosted Tailscale Funnel HTTPS address. MOB relay — coming soon.")
                }
            }
            .navigationTitle(existing == nil ? "Add machine" : "Pair \(existing?.name ?? "") again")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onChange(of: text) { parse() }
            .sheet(isPresented: $scanning) {
                QRScannerSheet { code in
                    guard (try? PairLink.parse(code)) != nil else { return false }
                    text = code
                    return true
                }
            }
            .interactiveDismissDisabled(busy)
        }
    }

    @ViewBuilder private func office(_ link: PairLink) -> some View {
        Section("Office Mac") {
            LabeledContent("Address", value: link.origin)
            if link.isInsecure {
                warning("Not encrypted: use only on a trusted network or a Tailscale/VPN address.")
            }
            if let t = target, moved {
                warning("This address differs from the one saved for \(t.name) (\(t.mobdUrl)). Pair only if the office Mac moved.")
            }
            if let t = target, otherOffice {
                warning("This link is for a different office than the one saved as \(t.name).")
            }
            if moved || otherOffice {
                Toggle("Use this address", isOn: $confirmed)
            }
            if target == nil {
                TextField("Name (Office Mac)", text: $officeName)
            }
        }
    }

    private func warning(_ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.waiting)
        }
    }

    private func parse() {
        confirmed = false
        error = nil
        do {
            link = try PairLink.parse(text)
            linkError = nil
        } catch {
            link = nil
            linkError = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : readable(error)
        }
    }

    private func start() {
        guard let link else { return }
        let target = target
        let name = officeName.trimmingCharacters(in: .whitespaces)
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                let result = try await pair(link: link, name: deviceName)
                try app.completePairing(link, result, existing: target, name: name.isEmpty ? "Office Mac" : name)
                dismiss()
            } catch {
                self.error = readable(error)
            }
        }
    }
}
