import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var phase
    @State private var editing: Machine?
    @State private var deleting: Machine?
    @State private var notificationsAllowed = true

    var body: some View {
        NavigationStack {
            Form {
                if app.activeMachine != nil { status }
                Section("Machines") {
                    if app.machines.isEmpty {
                        Text("No office Mac yet. Add the mobd URL of the Mac that runs the agent.").foregroundStyle(.secondary)
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
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Button { editing = m } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).accessibilityLabel("Edit \(m.name)")
                        }
                        .swipeActions { Button("Remove", role: .destructive) { deleting = m } }
                    }
                    Button { editing = app.newMachine() } label: { Label("Add machine", systemImage: "plus") }
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
                MachineEditor(initial: m, isNew: !app.machines.contains { $0.id == m.id }) { app.save($0) }
            }
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

private struct MachineEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var machine: Machine
    let isNew: Bool
    let onSave: (Machine) -> Void

    init(initial: Machine, isNew: Bool, onSave: @escaping (Machine) -> Void) {
        _machine = State(initialValue: initial)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name (Office Mac)", text: $machine.name)
                    TextField("mobd URL (http://192.168.1.100:8080)", text: $machine.mobdUrl)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    TextField("Mac user name", text: $machine.vncUsername)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Mac or VNC password", text: $machine.vncPassword)
                } header: {
                    Text("Desktop sign-in (optional)")
                } footer: {
                    Text("With a user name the live view signs in as that user, like Screen Sharing.app. A Screen Sharing (VNC) password alone, with no user name, opens the login window. Stored on this phone only; without either the desktop shows snapshots.")
                }
            }
            .navigationTitle(isNew ? "Add machine" : "Edit machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var m = machine
                        m.name = m.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Office Mac" : m.name.trimmingCharacters(in: .whitespaces)
                        m.mobdUrl = m.mobdUrl.trimmingCharacters(in: .whitespaces)
                        m.vncUsername = m.vncUsername.trimmingCharacters(in: .whitespaces)
                        onSave(m)
                        dismiss()
                    }
                    .disabled(machine.mobdUrl.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
