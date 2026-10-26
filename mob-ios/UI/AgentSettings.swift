import SwiftUI

/// settings.json, shared by every device: the default agent, and per agent its models, default
/// model and effort, and permissions.
struct AgentSettingsScreen: View {
    @Environment(AppState.self) private var app
    @State private var info: MachineSettingsInfo?
    @State private var edit: MachineSettings?
    @State private var adding: [String: String] = [:]
    @State private var message: (text: String, error: Bool)?
    @State private var saving = false
    @State private var confirm: [String]?

    private func label(_ name: String) -> String { info?.agents[name]?.label ?? name }

    /// An empty default sends none: the agent's own applies.
    private func agentDefault(_ value: String?) -> String { value.map { "Agent's default (\($0))" } ?? "Agent's default" }

    var body: some View {
        Form {
            if let info, let edit {
                Section {
                    Picker("Default agent", selection: binding(edit.defaultAgent) { s, v in s.defaultAgent = v }) {
                        ForEach(info.agents.keys.sorted(), id: \.self) { Text(label($0)).tag($0) }
                    }
                } footer: {
                    Text("Shared by every device paired with this machine. Each chat keeps the model and effort it started with; change them for one chat in its message box.")
                }
                ForEach(info.agents.keys.sorted(), id: \.self) { name in
                    if let a = edit.agents[name], let agent = info.agents[name] { agentSection(name, agent, a) }
                }
                if let message {
                    Section { Text(message.text).foregroundStyle(message.error ? .red : .green) }
                }
            } else if let message {
                Text(message.text).foregroundStyle(.red)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Agents")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(confirmed: false) }.disabled(edit == nil || edit == info?.settings || saving)
            }
        }
        .alert("Run without asking?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Allow and save", role: .destructive) { save(confirmed: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\((confirm ?? []).map(label).joined(separator: ", ")) will run commands and edit files on \(app.activeMachine?.name ?? "the office Mac") without asking you first.")
        }
        .task(id: app.settingsTick) { await load() }
    }

    @ViewBuilder
    private func agentSection(_ name: String, _ agent: MachineSettingsInfo.Agent, _ a: AgentSettings) -> some View {
        Section {
            ForEach(a.models, id: \.self) { m in
                Text(m).font(.body.monospaced())
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            update(name) { $0.models.removeAll { $0 == m }; if $0.defaultModel == m { $0.defaultModel = "" } }
                        }
                    }
            }
            HStack {
                TextField("Add a model ID", text: Binding(get: { adding[name] ?? "" }, set: { adding[name] = $0 }))
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { add(name, a.models) }
                Button("Add") { add(name, a.models) }.disabled((adding[name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Default model", selection: binding(a.defaultModel) { s, v in s = TurnSettings.with(s, agent: name) { $0.defaultModel = v } }) {
                Text(agentDefault(agent.agentDefaultModel)).tag("")
                ForEach(a.models, id: \.self) { Text($0).tag($0) }
            }
            Picker("Default effort", selection: binding(a.defaultEffort) { s, v in s = TurnSettings.with(s, agent: name) { $0.defaultEffort = v } }) {
                Text(agentDefault(agent.agentDefaultEffort)).tag("")
                ForEach(agent.efforts, id: \.self) { Text($0).tag($0) }
            }
            Picker("Permissions", selection: binding(a.permissions) { s, v in s = TurnSettings.with(s, agent: name) { $0.permissions = v } }) {
                Text("Run without asking").tag("bypass")
                Text("Ask before commands and edits").tag("approve")
            }
        } header: {
            Text(label(name))
        } footer: {
            Text(a.models.isEmpty ? "No models listed: chats use the default model." : "Swipe a model to remove it.")
        }
    }

    private func binding(_ value: String, _ set: @escaping (inout MachineSettings, String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: { v in
            guard var e = edit else { return }
            set(&e, v)
            edit = e
            message = nil
        })
    }

    private func update(_ name: String, _ change: (inout AgentSettings) -> Void) {
        guard let e = edit else { return }
        edit = TurnSettings.with(e, agent: name, change)
        message = nil
    }

    private func add(_ name: String, _ models: [String]) {
        switch TurnSettings.add(model: adding[name] ?? "", to: models) {
        case .success(let next):
            update(name) { $0.models = next }
            adding[name] = ""
        case .failure(let e):
            message = (e.localizedDescription, true)
        }
    }

    private func load() async {
        do {
            let v = try await app.apiClient.settings()
            info = v
            // Keep local edits unless another device saved meanwhile.
            if edit == nil || edit?.rev != v.settings.rev { edit = v.settings }
        } catch {
            message = (readable(error), true)
        }
    }

    private func save(confirmed: Bool) {
        guard let info, let edit else { return }
        let risky = TurnSettings.newlyUnguarded(info.settings, edit)
        if !risky.isEmpty && !confirmed { return confirm = risky }
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved = try await app.apiClient.saveSettings(edit)
                self.info = saved
                self.edit = saved.settings
                message = ("Saved. New chats use these defaults; open chats keep theirs.", false)
                app.checkHealth()
            } catch let e as APIError where e.code == "settings_changed" {
                self.edit = nil
                await load()
                message = ("Another device changed these settings. They are reloaded; make your change again.", true)
            } catch {
                message = (readable(error), true)
            }
        }
    }
}
