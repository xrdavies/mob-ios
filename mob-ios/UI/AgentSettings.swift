import SwiftUI

/// Machine settings shared by every device: the default agent, and per agent its models,
/// default model and effort, and permissions (mobd with "settings").
struct AgentSettingsScreen: View {
    @Environment(AppState.self) private var app
    @State private var view: MachineSettingsInfo?
    @State private var edit: MachineSettings?
    @State private var adding: [String: String] = [:]
    @State private var message: (text: String, error: Bool)?
    @State private var saving = false
    @State private var confirm: [String]?

    private func label(_ name: String) -> String { app.health?.runners?.first { $0.name == name }?.title ?? name }

    var body: some View {
        Form {
            if let view, let edit {
                Section {
                    Picker("Default agent", selection: binding(edit.defaultAgent ?? "") { s, v in s.defaultAgent = v.isEmpty ? nil : v }) {
                        Text("\(label(view.fallbackDefaultAgent ?? view.defaultAgent)) (\(TurnSettings.fromLabel("config")))").tag("")
                        ForEach(view.agents.keys.sorted(), id: \.self) { Text(label($0)).tag($0) }
                    }
                } footer: {
                    Text("Shared by every device paired with this machine. Each chat keeps the model and effort it started with; change them for one chat in its message box.")
                }
                ForEach(view.agents.keys.sorted(), id: \.self) { name in agentSection(name, view.agents[name]!, edit) }
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
                Button("Save") { save(confirmed: false) }.disabled(edit == nil || edit == view?.settings || saving)
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
    private func agentSection(_ name: String, _ now: MachineSettingsInfo.Agent, _ edit: MachineSettings) -> some View {
        let a = edit.agents?[name] ?? AgentSettings()
        let back = now.fallback
        let models = a.models ?? back?.models ?? now.models
        let fallbackText = { (value: String?, from: String) in value.map { "\($0) (\(TurnSettings.fromLabel(from)))" } ?? TurnSettings.fromLabel("builtin") }
        Section {
            ForEach(models, id: \.self) { m in
                Text(m).font(.body.monospaced())
                    .swipeActions {
                        Button("Remove", role: .destructive) {
                            update(name) { $0.models = models.filter { $0 != m }; if $0.defaultModel == m { $0.defaultModel = nil } }
                        }
                    }
            }
            HStack {
                TextField("Add a model ID", text: Binding(get: { adding[name] ?? "" }, set: { adding[name] = $0 }))
                    .font(.body.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .onSubmit { add(name, models) }
                Button("Add") { add(name, models) }.disabled((adding[name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Picker("Default model", selection: binding(a.defaultModel ?? "") { s, v in s = TurnSettings.with(s, agent: name) { $0.defaultModel = v } }) {
                Text(fallbackText(back?.defaultModel, back?.defaultModelFrom ?? "builtin")).tag("")
                ForEach(models, id: \.self) { Text($0).tag($0) }
            }
            Picker("Default effort", selection: binding(a.defaultEffort ?? "") { s, v in s = TurnSettings.with(s, agent: name) { $0.defaultEffort = v } }) {
                Text(fallbackText(back?.defaultEffort, back?.defaultEffortFrom ?? "builtin")).tag("")
                ForEach(now.efforts, id: \.self) { Text($0).tag($0) }
            }
            Picker("Permissions", selection: binding(a.permissions ?? "") { s, v in s = TurnSettings.with(s, agent: name) { $0.permissions = v } }) {
                Text("\(permissionLabel(back?.permissions ?? now.permissions)) (\(TurnSettings.fromLabel("config")))").tag("")
                Text(permissionLabel("bypass")).tag("bypass")
                Text(permissionLabel("approve")).tag("approve")
            }
        } header: {
            Text(label(name))
        } footer: {
            if a.models == nil { Text("Models \(TurnSettings.fromLabel(back?.modelsFrom ?? now.modelsFrom)). Swipe to remove one.") }
        }
    }

    private func permissionLabel(_ p: String) -> String { p == "approve" ? "Ask before commands and edits" : "Run without asking" }

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
            view = v
            // Keep local edits unless another device saved meanwhile.
            if edit == nil || edit?.rev != v.settings.rev { edit = v.settings }
        } catch {
            message = (readable(error), true)
        }
    }

    private func save(confirmed: Bool) {
        guard let view, let edit else { return }
        let risky = TurnSettings.newlyUnguarded(view, edit)
        if !risky.isEmpty && !confirmed { return confirm = risky }
        saving = true
        Task {
            defer { saving = false }
            do {
                let saved = try await app.apiClient.saveSettings(edit)
                self.view = saved
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
