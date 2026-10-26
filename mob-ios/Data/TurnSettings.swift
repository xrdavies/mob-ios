import Foundation

// Machine settings (GET/PUT /settings) and which model and effort the message box shows and
// sends (mobd docs/mobd-v3.md, "Machine and conversation settings"). "" means the default:
// the machine's for a new chat, the conversation's otherwise.

typealias Permissions = String

/// What the apps set for one agent; nil or empty = not set here.
struct AgentSettings: Codable, Equatable {
    var models: [String]?
    var defaultModel: String?
    var defaultEffort: String?
    var permissions: Permissions?

    var isEmpty: Bool { (models ?? []).isEmpty && (defaultModel ?? "").isEmpty && (defaultEffort ?? "").isEmpty && (permissions ?? "").isEmpty }
}

struct MachineSettings: Codable, Equatable {
    var rev: Int64
    var defaultAgent: String?
    var agents: [String: AgentSettings]?
}

/// What an agent uses now, and where each value comes from (app, config, agent, builtin).
struct EffectiveAgent: Codable, Equatable {
    var models: [String]
    var modelsFrom: String
    var defaultModel: String?
    var defaultModelFrom: String
    var defaultEffort: String?
    var defaultEffortFrom: String
    var permissions: Permissions
    var permissionsFrom: String
    var efforts: [String]
}

struct MachineSettingsInfo: Codable, Equatable {
    struct Agent: Codable, Equatable {
        var models: [String]
        var modelsFrom: String
        var defaultModel: String?
        var defaultModelFrom: String
        var defaultEffort: String?
        var defaultEffortFrom: String
        var permissions: Permissions
        var permissionsFrom: String
        var efforts: [String]
        /// What applies without the app settings: what clearing a value returns to.
        var fallback: EffectiveAgent?
    }
    var settings: MachineSettings
    var defaultAgent: String
    var defaultAgentFrom: String
    var fallbackDefaultAgent: String?
    var agents: [String: Agent]
}

struct TurnChoice: Equatable {
    var model = ""
    var effort = ""
}

enum TurnSettings {
    /// What the menus show: with mobd settings an open chat shows its conversation's values;
    /// a new chat (or an older mobd) shows the draft picked on this device.
    static func shown(settings: Bool, session: Session?, draftModel: String?, draftEffort: String?) -> TurnChoice {
        if settings, let session { return TurnChoice(model: session.model ?? "", effort: session.effort ?? "") }
        return TurnChoice(model: draftModel ?? "", effort: draftEffort ?? "")
    }

    /// The models offered: the agent's list, plus a value in use that is no longer listed.
    static func menuModels(_ models: [String], current: String) -> [String] {
        !current.isEmpty && !models.contains(current) ? models + [current] : models
    }

    /// What a turn sends: mobd fills a new chat from the machine defaults and a later turn from
    /// its conversation, so only a draft is sent; an older mobd gets the choice on every turn.
    static func sent(settings: Bool, newChat: Bool, shown: TurnChoice, efforts: [String]) -> (model: String?, effort: String?) {
        if settings && !newChat { return (nil, nil) }
        return (shown.model.isEmpty ? nil : shown.model, efforts.contains(shown.effort) ? shown.effort : nil)
    }

    /// Applies a change to one agent; empty values mean "not set here".
    static func with(_ s: MachineSettings, agent name: String, _ change: (inout AgentSettings) -> Void) -> MachineSettings {
        var s = s
        var a = s.agents?[name] ?? AgentSettings()
        change(&a)
        if a.models?.isEmpty == true { a.models = nil }
        if a.defaultModel?.isEmpty == true { a.defaultModel = nil }
        if a.defaultEffort?.isEmpty == true { a.defaultEffort = nil }
        if a.permissions?.isEmpty == true { a.permissions = nil }
        var agents = s.agents ?? [:]
        agents[name] = a.isEmpty ? nil : a
        s.agents = agents
        return s
    }

    /// Adds a typed model ID once; an error message when it is not a model name.
    static func add(model raw: String, to models: [String]) -> Result<[String], ModelNameError> {
        let m = raw.trimmingCharacters(in: .whitespaces)
        guard m.range(of: #"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,127}$"#, options: .regularExpression) != nil else { return .failure(ModelNameError()) }
        return .success(models.contains(m) ? models : models + [m])
    }

    /// Agents a save would let run without asking that ask today.
    static func newlyUnguarded(_ view: MachineSettingsInfo, _ next: MachineSettings) -> [String] {
        view.agents.compactMap { name, now in
            let after = next.agents?[name]?.permissions ?? (now.fallback?.permissions ?? now.permissions)
            return now.permissions == "approve" && after == "bypass" ? name : nil
        }.sorted()
    }

    static func fromLabel(_ from: String) -> String {
        ["app": "set in Mob", "config": "from mobd config", "agent": "from the agent's own config", "builtin": "agent's built-in default"][from] ?? from
    }
}

struct ModelNameError: Error, LocalizedError {
    var errorDescription: String? { "Model names use letters, digits and . _ : / - (no spaces)." }
}
