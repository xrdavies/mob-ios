import PhotosUI
import SwiftUI

private let maxAttachments = 10

/// An image picked for the next turn: uploading, uploaded (id) or failed.
@MainActor @Observable
private final class Attachment: Identifiable {
    let id = UUID()
    var preview: UIImage?
    var uploadId: String?
    var error: String?
}

/// Prompt box with images, agent / model / effort, Stop, and adding to a running turn.
/// Like the desktop app: one turn at a time per chat; while a turn runs you can draft the next
/// message, or send it into the turn when the agent supports steering.
struct Composer: View {
    @Environment(AppState.self) private var app
    @State private var text = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var attachments: [Attachment] = []
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
        let models = runner?.models ?? h?.models ?? []
        let efforts = runner?.efforts ?? h?.efforts ?? []
        let canOptions = h?.supports("taskOptions") == true
        let model = app.turnPrefs["\(runnerKey).model"].flatMap { models.isEmpty || models.contains($0) ? $0 : nil }
        let effort = app.turnPrefs["\(runnerKey).effort"].flatMap { efforts.contains($0) ? $0 : nil }
        let canUpload = h?.supports("uploads") == true && runner?.images != false
        let task = chat.detail?.current
        let busy = chat.detail?.busy == true
        let canSteer = task?.status == Status.running && runner?.steer == true && h?.supports("steer") == true && !chat.cancelling
        let uploading = attachments.contains { $0.uploadId == nil && $0.error == nil }

        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(attachments) { chip($0) } }
                }
            }
            TextField(placeholder(canSteer: canSteer, busy: busy), text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                .disabled(!app.isConnected)
            HStack(spacing: 6) {
                PhotosPicker(selection: $picked, maxSelectionCount: maxAttachments - attachments.count, matching: .images) {
                    Image(systemName: "photo.badge.plus")
                }
                .disabled(!app.isConnected || !canUpload || attachments.count >= maxAttachments)
                .accessibilityLabel("Attach images")

                if chat.currentId == nil && available.count > 1 {
                    option("cpu", runner?.title ?? "Agent", nil, available.map { ($0.name, $0.title) }, runner?.name) { app.setTurnPref("\(m).runner", $0) }
                } else if chat.currentId != nil, let runner, (h?.runners?.count ?? 0) > 1 {
                    Text(runner.title).font(.caption).foregroundStyle(.secondary)
                }
                if canOptions && !models.isEmpty {
                    option("memorychip", model ?? "Model", "Default model", models.map { ($0, $0) }, model) { app.setTurnPref("\(runnerKey).model", $0) }
                }
                if canOptions && !efforts.isEmpty {
                    option("brain", effort ?? "Effort", "Default effort", efforts.map { ($0, $0) }, effort) { app.setTurnPref("\(runnerKey).effort", $0) }
                }
                Spacer()
                if busy {
                    if canSteer && !text.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button { send(canSteer: true, busy: true, uploading: false, runner: nil, model: nil, effort: nil) } label: {
                            Image(systemName: "arrow.up").font(.body.weight(.semibold))
                        }
                        .buttonStyle(.bordered).clipShape(Circle())
                        .disabled(chat.sending)
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
                        send(canSteer: false, busy: false, uploading: uploading, runner: chat.currentId == nil ? runner?.name : nil,
                             model: canOptions ? model : nil, effort: canOptions ? effort : nil)
                    } label: {
                        if chat.sending { ProgressView() } else { Image(systemName: "arrow.up").font(.body.weight(.semibold)) }
                    }
                    .buttonStyle(.borderedProminent).clipShape(Circle())
                    .disabled(!app.isConnected || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.sending || uploading)
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

    private func send(canSteer: Bool, busy: Bool, uploading: Bool, runner: String?, model: String?, effort: String?) {
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        if canSteer {
            chat.steer(prompt) { ok in if ok && text.trimmingCharacters(in: .whitespacesAndNewlines) == prompt { text = "" } }
            return
        }
        guard !busy, !uploading, !chat.sending else { return }
        // Clear at once: the message shows in the chat while it is sent.
        let sent = attachments
        text = ""
        attachments = []
        chat.send(prompt, runner: runner, model: model, effort: effort, attachments: sent.compactMap(\.uploadId)) { ok in
            // Not sent: give the text back, unless something new was typed meanwhile.
            guard !ok, text.isEmpty else { return }
            text = prompt
            attachments = sent
        }
    }

    /// Uploads picked photos right away, like the desktop app.
    private func load(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        picked = []
        let client = app.apiClient
        for (i, item) in items.prefix(maxAttachments - attachments.count).enumerated() {
            let a = Attachment()
            attachments.append(a)
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
                    app.noteFailure(error)
                }
            }
        }
    }

    private func chip(_ a: Attachment) -> some View {
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
            Button { attachments.removeAll { $0.id == a.id } } label: {
                Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
            }
            .offset(x: 4, y: -4)
            .accessibilityLabel("Remove image")
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
