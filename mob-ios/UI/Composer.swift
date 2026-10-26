import PhotosUI
import SwiftUI

private let maxAttachments = 10

/// Prompt box with images, agent / model / effort, Stop, and adding to a running turn.
/// Like the desktop app: one turn at a time per chat; while a turn runs you can draft the next
/// message, or send it into the turn when the agent supports steering.
struct Composer: View {
    @Environment(AppState.self) private var app
    @Bindable var draft: ChatDraft
    @State private var picked: [PhotosPickerItem] = []
    @FocusState private var focused: Bool

    private var chat: ChatStore { app.chat }

    var body: some View {
        let h = app.health
        let m = app.activeMachineId ?? ""
        let available = (h?.runners ?? []).filter { $0.available != false }
        // A conversation keeps its runner; a new chat uses the picked one while it is available.
        let pickedRunner = chat.currentId != nil ? chat.detail?.session.runner : available.first { $0.name == app.turnPrefs["\(m).runner"] }?.name
        let runner = h?.runner(pickedRunner)
        let runnerKey = "\(m)/\(runner?.name ?? h?.runner ?? "")"
        let models = runner?.models ?? []
        let efforts = runner?.efforts ?? []
        let canOptions = h?.supports("taskOptions") == true
        // An open chat shows and changes its conversation's model and effort (shared by every
        // device); a new chat keeps a draft on this device until it exists.
        let shown = TurnSettings.shown(session: chat.currentId != nil ? chat.detail?.session : nil,
                                       draftModel: app.turnPrefs["\(runnerKey).model"], draftEffort: app.turnPrefs["\(runnerKey).effort"])
        let model: String? = shown.model.isEmpty ? nil : shown.model
        let effort: String? = shown.effort.isEmpty ? nil : shown.effort
        let choose = { (key: String, value: String?) in
            if chat.currentId != nil {
                chat.setTurnSettings(model: key == "model" ? value ?? "" : nil, effort: key == "effort" ? value ?? "" : nil)
            } else {
                app.setTurnPref("\(runnerKey).\(key)", value)
            }
        }
        let canUpload = h?.supports("uploads") == true && runner?.images != false
        let task = chat.detail?.current
        let busy = chat.detail?.busy == true
        let canSteer = task?.status == Status.running && runner?.steer == true && h?.supports("steer") == true && !chat.cancelling
        let text = draft.text
        let attachments = draft.attachments
        let uploading = !draft.attachmentsReady

        VStack(alignment: .leading, spacing: 8) {
            if let task {
                Text("Current turn · \(task.modelLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(attachments) { chip($0) } }
                }
            }
            if attachments.contains(where: { $0.error != nil }) {
                Text("An image could not be uploaded. Remove it and attach it again before sending.")
                    .font(.caption).foregroundStyle(.red)
            }
            TextField(placeholder(canSteer: canSteer, busy: busy), text: $draft.text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!app.isConnected || draft.sending)
            HStack(spacing: 6) {
                PhotosPicker(selection: $picked, maxSelectionCount: maxAttachments - attachments.count, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                }
                .disabled(!app.isConnected || !canUpload || draft.sending || attachments.count >= maxAttachments)
                .accessibilityLabel("Attach images")

                if chat.currentId == nil && available.count > 1 {
                    option("cpu", runner?.title ?? "Agent", nil, available.map { ($0.name, $0.title) }, runner?.name) { app.setTurnPref("\(m).runner", $0) }
                } else if chat.currentId != nil, let runner, (h?.runners?.count ?? 0) > 1 {
                    Text(runner.title).font(.caption).foregroundStyle(.secondary)
                }
                let defaultModel = defaultLabel("model", runner?.defaultModel)
                let defaultEffort = defaultLabel("effort", runner?.defaultEffort)
                if canOptions && (!models.isEmpty || runner?.defaultModel != nil) {
                    option("memorychip", model ?? defaultModel, defaultModel, TurnSettings.menuModels(models, current: shown.model).map { ($0, $0) }, model) { choose("model", $0) }
                }
                if canOptions && !efforts.isEmpty {
                    option("brain", effort ?? defaultEffort, defaultEffort, efforts.map { ($0, $0) }, effort) { choose("effort", $0) }
                }
                Spacer()
                if busy {
                    if canSteer && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { send(canSteer: true, busy: true, uploading: false, runner: nil, model: nil, effort: nil) } label: {
                            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        }
                        .buttonStyle(.bordered).clipShape(Circle())
                        .disabled(!app.isConnected || chat.sending || draft.sending || !attachments.isEmpty)
                        .accessibilityLabel("Send to running turn")
                    }
                    Button { chat.cancel() } label: {
                        if chat.cancelling { ProgressView().tint(.white) } else { Image(systemName: "stop.fill") }
                    }
                    .buttonStyle(.borderedProminent).tint(.red).clipShape(Circle())
                    .disabled(chat.cancelling)
                    .accessibilityLabel("Stop")
                } else {
                    Button {
                        // Only a new chat names them (they become its settings); later turns use the conversation's.
                        let newChat = chat.currentId == nil
                        send(canSteer: false, busy: false, uploading: uploading, runner: newChat ? runner?.name : nil,
                             model: canOptions && newChat ? model : nil,
                             effort: canOptions && newChat && efforts.contains(shown.effort) ? effort : nil,
                             clearDraft: newChat ? (m, runnerKey) : nil)
                    } label: {
                        if chat.sending { ProgressView() } else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                    }
                    .buttonStyle(.borderedProminent).clipShape(Circle())
                    .disabled(!app.isConnected || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.sending || draft.sending || uploading)
                    .accessibilityLabel("Send")
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.bar)
        .onChange(of: picked) { load(picked) }
    }

    private func placeholder(canSteer: Bool, busy: Bool) -> String {
        if canSteer { return "Add to what the agent is doing…" }
        if busy { return "The agent is working… you can draft the next message" }
        return "Ask Mob to do something on \(app.activeMachine?.name ?? "the office Mac")…"
    }

    private func send(canSteer: Bool, busy: Bool, uploading: Bool, runner: String?, model: String?, effort: String?,
                      clearDraft: (machine: String, runnerKey: String)? = nil) {
        let draft = draft
        let prompt = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !draft.sending, !chat.sending else { return }
        if canSteer {
            guard draft.attachments.isEmpty else { return }
            draft.beginSending()
            chat.steer(prompt) { draft.finishSending($0) }
            return
        }
        guard !busy, !uploading, draft.attachmentsReady else { return }
        // Keep the draft until accepted, so a failed request never loses text or images.
        draft.beginSending()
        chat.send(prompt, runner: runner, model: model, effort: effort, attachments: draft.attachments.compactMap(\.uploadId)) { ok in
            draft.finishSending(ok)
            // The conversation has its settings now; the next new chat starts from the defaults.
            if ok, let clearDraft { app.clearTurnPrefs(machine: clearDraft.machine, runnerKey: clearDraft.runnerKey) }
        }
    }

    /// Uploads picked photos right away, like the desktop app.
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        let draft = draft
        guard !draft.sending else { return }
        let client = app.apiClient
        for (i, item) in items.prefix(maxAttachments - draft.attachments.count).enumerated() {
            let a = DraftAttachment()
            draft.attachments.append(a)
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
                        a.error = "Cannot read this photo"
                        return
                    }
                    a.preview = image.preparingThumbnail(of: CGSize(width: 160, height: 160)) ?? image
                    a.uploadId = try await client.upload(image, name: "photo-\(i + 1)").id
                } catch {
                    a.error = readable(error)
                    Log.error("upload failed: \(readable(error))")
                    app.noteFailure(error, client: client)
                }
            }
        }
    }

    private func chip(_ a: DraftAttachment) -> some View {
        ZStack(alignment: .topTrailing) {
            ZStack {
                Color(.secondarySystemBackground)
                if let p = a.preview { Image(uiImage: p).resizable().scaledToFill() }
                if a.error != nil { Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red) }
                else if a.uploadId == nil { ProgressView() }
            }
            .frame(width: 64, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(a.error != nil ? Color.red : .clear))
            Button { draft.attachments.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove image")
            .disabled(draft.sending)
        }
        .padding(.top, 4)
    }

    private func option(_ icon: String, _ label: String, _ defaultLabel: String?, _ options: [(String, String)], _ value: String?,
                        _ onChange: @escaping (String?) -> Void) -> some View {
        Menu {
            if let defaultLabel {
                Button { onChange(nil) } label: { if value == nil { Label(defaultLabel, systemImage: "checkmark") } else { Text(defaultLabel) } }
            }
            ForEach(options, id: \.0) { v, title in
                Button { onChange(v) } label: { if v == value { Label(title, systemImage: "checkmark") } else { Text(title) } }
            }
        } label: {
            Label(label, systemImage: icon).font(.caption).lineLimit(1)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(.secondarySystemBackground), in: Capsule())
        }
    }
}
