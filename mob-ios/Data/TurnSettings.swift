import Foundation

// settings.json (GET/PUT /settings) and which model and effort the message box shows and sends
// (mobd docs/mobd-v3.md, "Settings"). "" means the default from settings.json; an empty default
// sends none, so the agent's own applies.

/// One agent's settings in settings.json.
struct AgentSettings: Codable, Equatable {
    var models: [String] = []
    var defaultModel = ""
    var defaultEffort = ""
    var permissions = "bypass"
}

/// settings.json: the runtime settings of agents and conversations, shared by every device.
struct MachineSettings: Codable, Equatable {
    var rev: Int64
    var defaultAgent: String
    var agents: [String: AgentSettings]
}

/// GET /settings: the file, and per agent its label, efforts and own defaults.
struct MachineSettingsInfo: Codable, Equatable {
    struct Agent: Codable, Equatable {
        var label: String
        var efforts: [String]
        var agentDefaultModel: String?
        var agentDefaultEffort: String?
    }
    /// Whether a supported agent is set up on the machine, enabled or not.
    struct Installed: Codable, Equatable, Identifiable {
        var name: String
        var label: String
        var state: String
        var enabled: Bool
        var detail: String?
        var install: String?
        var id: String { name }

        /// ready, disabled (installed, not enabled), missing, error.
        var stateLabel: String {
            ["disabled": "Installed, not enabled", "missing": "Not installed", "error": "Not working"][state] ?? state
        }
    }
    var settings: MachineSettings
    var agents: [String: Agent]
    var installed: [Installed]?
}

struct TurnChoice: Equatable {
    var model = ""
    var effort = ""
}

enum TurnSettings {
    /// What the menus show: an open chat its conversation's values, a new chat this device's draft.
    static func shown(session: Session?, draftModel: String?, draftEffort: String?) -> TurnChoice {
        if let session { return TurnChoice(model: session.model ?? "", effort: session.effort ?? "") }
        return TurnChoice(model: draftModel ?? "", effort: draftEffort ?? "")
    }

    /// The models offered: the agent's list, plus a value in use that is no longer listed.
    static func menuModels(_ models: [String], current: String) -> [String] {
        !current.isEmpty && !models.contains(current) ? models + [current] : models
    }

    /// Applies a change to one agent's settings.
    static func with(_ s: MachineSettings, agent name: String, _ change: (inout AgentSettings) -> Void) -> MachineSettings {
        var s = s
        var a = s.agents[name] ?? AgentSettings()
        change(&a)
        s.agents[name] = a
        return s
    }

    /// Adds a typed model ID once; an error when it is not a model name.
    static func add(model raw: String, to models: [String]) -> Result<[String], ModelNameError> {
        let m = raw.trimmingCharacters(in: .whitespaces)
        guard m.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$"#, options: .regularExpression) != nil else { return .failure(ModelNameError()) }
        return .success(models.contains(m) ? models : models + [m])
    }

    /// Agents a save would let run without asking that ask today (they need a confirmation).
    static func newlyUnguarded(_ before: MachineSettings, _ after: MachineSettings) -> [String] {
        before.agents.compactMap { name, a in
            a.permissions == "approve" && after.agents[name]?.permissions == "bypass" ? name : nil
        }.sorted()
    }
}

struct ModelNameError: Error, LocalizedError {
    var errorDescription: String? { "Model names use letters, digits and . _ : / - (no spaces)." }
}
