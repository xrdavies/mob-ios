import SwiftUI

/// The agent's name next to its title: "@api" in the header and chat list.
struct HandleBadge: View {
    let handle: String?

    var body: some View {
        if let handle, !handle.isEmpty {
            Text("@\(handle)")
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Color.accentColor.opacity(0.15), in: Capsule())
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel("Handle @\(handle)")
        }
    }
}

/// Sets, changes, moves or removes a conversation's handle (Desktop's HandleDialog). A handle another
/// conversation holds is moved only after the sheet says whose it is.
struct HandleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var value: String
    @State private var error: String?
    /// mobd said another conversation (not in the list, e.g. archived) holds this handle.
    @State private var takenElsewhere: String?
    @State private var saving = false
    @FocusState private var focused: Bool

    init(session: Session) {
        self.session = session
        _value = State(initialValue: session.handle ?? "")
    }

    private var current: String { session.handle ?? "" }
    private var suggested: String? {
        let taken = Set(app.chat.sessions.filter { $0.id != session.id }.compactMap(\.handle))
        return Handle.suggest(from: session.displayTitle, taken: taken)
    }
    private var problem: String { value.isEmpty ? "" : Collab.handleProblem(value) }
    private var holder: Session? { app.chat.sessions.first { $0.handle == value && $0.id != session.id } }
    private var moving: Bool { problem.isEmpty && !value.isEmpty && (holder != nil || takenElsewhere == value) }
    private var canSave: Bool { !value.isEmpty && problem.isEmpty && value != current && !saving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: "at").font(.headline).foregroundStyle(Color.accentColor)
                            .frame(width: 36, height: 36).background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(current.isEmpty ? "Give this agent a handle" : "Change handle").font(.headline)
                            Text([session.displayTitle, session.runner].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 2) {
                            Text("@").font(.body.monospaced()).foregroundStyle(.secondary)
                            TextField("order-service", text: Binding(get: { value }, set: { value = Collab.normalizeHandleInput($0); error = nil }))
                                .font(.body.monospaced())
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focused).submitLabel(.done).onSubmit { if canSave { save(value, take: moving) } }
                                .accessibilityIdentifier("handle-field")
                            Text("\(value.count)/32").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).frame(height: 44)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(problem.isEmpty && error == nil ? Color.clear : .red, lineWidth: 1))
                        Text(!problem.isEmpty ? problem : error ?? "Lowercase letters, digits and -. Unique on this office computer.")
                            .font(.caption).foregroundStyle(problem.isEmpty && error == nil ? Color.secondary : .red)
                        if current.isEmpty, let suggested, value != suggested {
                            Button { value = suggested } label: { Text("Use @\(suggested)").font(.caption.monospaced()) }
                                .buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                    if moving {
                        Label {
                            Text("@\(value) belongs to \(holder.map { "\"\($0.displayTitle)\"" } ?? "an archived conversation"). Moving it leaves that conversation without a handle; its past requests keep their names.")
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        .font(.caption).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    } else {
                        Text("In another conversation, type @\(!value.isEmpty && problem.isEmpty ? value : "handle") to ask this agent for help. The title keeps describing its work.")
                            .font(.caption).foregroundStyle(.secondary).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
                    }
                    Button { save(value, take: moving) } label: {
                        HStack { if saving { ProgressView() }; Text(moving ? "Move @\(value) here" : current.isEmpty ? "Set handle" : "Save") }
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!canSave)
                    if !current.isEmpty {
                        Button("Remove @\(current)", role: .destructive) { save("", take: false) }
                            .frame(maxWidth: .infinity).disabled(saving)
                    }
                }
                .padding(20)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) } }
            .onAppear {
                if value.isEmpty, let suggested { value = suggested }
                focused = true
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func save(_ handle: String, take: Bool) {
        saving = true
        app.chat.setHandle(session, handle, take: take) { e in
            saving = false
            if let e, e.status == 409 || e.message.contains("belongs to another conversation") {
                takenElsewhere = handle
            } else if let e {
                error = e.message
            } else {
                dismiss()
            }
        }
    }
}

/// The pending-collaboration strip above the timeline: independent of paged history.
struct CollabStrip: View {
    @Environment(AppState.self) private var app
    @State private var detail: CollabRequest?

    var body: some View {
        let store = app.collab
        let shown = store.pending
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(shown) { r in
                    Button { detail = r } label: { line(r) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            .sheet(item: $detail) { r in
                CollabDetail(request: r, session: app.chat.currentId)
            }
        }
    }

    private func line(_ r: CollabRequest) -> some View {
        let session = app.chat.currentId
        let peer = r.peerName(from: session)
        let needs = r.needsUser
        return HStack(spacing: 6) {
            Image(systemName: needs ? "exclamationmark.circle" : "arrow.triangle.swap").foregroundStyle(needs ? .orange : .secondary)
            Text(peer.hasPrefix("@") ? peer : "@\(peer)").font(.caption.weight(.semibold))
            Text(needs ? "needs you" : r.statusLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if needs {
                Button("Dismiss") { app.collab.dismiss(r.id) }.font(.caption)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One request: what was asked, the back-and-forth, the result, and Cancel.
struct CollabDetail: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let request: CollabRequest
    let session: String?

    var body: some View {
        NavigationStack {
            List {
                Section("From \(request.peerName(from: session) == request.toName ? (request.fromName ?? "") : (request.toName ?? ""))") {
                    Text(request.text).textSelection(.enabled)
                }
                Section("Status") { Text(request.statusLabel) }
                if let thread = request.thread, !thread.isEmpty {
                    Section("Thread") {
                        ForEach(Array(thread.enumerated()), id: \.offset) { _, n in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(n.kind == "answer" ? "Answer" : "Question").font(.caption).foregroundStyle(.secondary)
                                Text(n.text).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let result = request.result, !result.isEmpty {
                    Section("Result") { Text(result).textSelection(.enabled) }
                }
                if request.isOpen {
                    Section {
                        Button("Cancel request", role: .destructive) {
                            app.collab.cancel(request.id, client: app.apiClient) { ok in if ok { dismiss() } }
                        }
                    } footer: {
                        Text("Stops waiting for this answer. The other agent is told it was cancelled.")
                    }
                }
            }
            .navigationTitle("Collaboration")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The "@" picker above the composer: agents with a handle, then other conversations. Picking one
/// without a handle offers to name it first (`naming`), so mentions stay readable.
struct MentionPicker: View {
    let candidates: [MentionCandidate]
    let naming: (session: Session, handle: String?)?
    let onPick: (MentionCandidate) -> Void
    let onName: () -> Void
    let onPlain: () -> Void
    let onBack: () -> Void

    var body: some View {
        Group {
            if let naming { namingPanel(naming.session, naming.handle) }
            else if !candidates.isEmpty { list }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private var list: some View {
        let agents = candidates.filter { $0.session.handle?.isEmpty == false }
        let others = candidates.filter { $0.session.handle?.isEmpty != false }
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !agents.isEmpty { section("Agents", agents) }
                if !others.isEmpty { section("Conversations", others) }
            }
        }
        .frame(maxHeight: 260)
        .accessibilityIdentifier("mention-picker")
    }

    private func section(_ title: String, _ items: [MentionCandidate]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 2)
            ForEach(items) { c in
                Button { onPick(c) } label: {
                    HStack(spacing: 6) {
                        if let h = c.session.handle, !h.isEmpty { Text("@\(h)").font(.subheadline.monospaced().weight(.medium)) }
                        Text(c.session.displayTitle).font(.subheadline).lineLimit(1)
                            .foregroundStyle(c.session.handle == nil ? Color.primary : .secondary)
                        Spacer(minLength: 6)
                        Text(c.archived ? "archived" : [c.session.handle == nil ? c.shortId : nil, runnerTitle(c.session.runner)].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(c.archived)
                .opacity(c.archived ? 0.45 : 1)
                .accessibilityHint(c.archived ? "Archived. Unarchive it to mention it." : "")
            }
        }
    }

    private func namingPanel(_ s: Session, _ handle: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Give \(s.displayTitle) a handle?").font(.subheadline).lineLimit(2)
            Text("You and other agents can then mention it by name instead of its ID.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                if let handle {
                    Button { onName() } label: { Text("Name it @\(handle)").font(.caption.monospaced()) }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                Button { onPlain() } label: { Text("Mention as @\(Collab.shortId(s.id))").font(.caption.monospaced()) }
                    .buttonStyle(.bordered).controlSize(.small)
                Spacer()
                Button("Back", action: onBack).font(.caption)
            }
        }
        .padding(12)
        .accessibilityIdentifier("mention-naming")
    }
}

private let runnerTitles = ["codex": "Codex", "claude": "Claude Code", "pi": "Pi"]
func runnerTitle(_ r: String?) -> String? { r.flatMap { runnerTitles[$0] ?? $0 } }

/// An agent's coloured initial, the same colour wherever it appears.
struct AgentAvatar: View {
    let id: String
    let label: String

    var body: some View {
        let initial = label.first { $0.isLetter || $0.isNumber }.map { String($0).uppercased() } ?? "?"
        Text(initial).font(.caption.weight(.semibold)).foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background(Color(hue: Collab.hue(id), saturation: 0.6, brightness: 0.75), in: Circle())
            .accessibilityHidden(true)
    }
}

/// A turn mobd started to deliver other agents' messages: each on the left with the agent's name,
/// colour and what it did, without mobd's instructions to the recipient. Only the user is on the right.
struct PeerMessage: View {
    @Environment(AppState.self) private var app
    let message: Message
    let task: AgentTask?

    private struct Part: Hashable {
        let sender: String?
        let name: String
        let label: String
        let body: String
        let context: String?
    }

    private var parts: [Part] {
        let sessions = app.chat.sessions
        if let ds = task?.origin?.deliveries, !ds.isEmpty {
            return ds.map { d in
                let r = app.collab.list.first { $0.id == d.requestId }
                let sender = r.flatMap { Collab.sender(d, $0) }
                let s = sessions.first { $0.id == sender }
                let saved = r.flatMap { r in sender == r.from ? r.fromName : r.toName } ?? "Mob"
                return Part(sender: sender, name: s.map { Collab.shortLabel($0) } ?? saved, label: Collab.label(d, r), body: d.text,
                            context: d.kind != "request" ? r?.text : nil)
            }
        }
        return Collab.parseDelivery(message.content).map { p in
            let s = sessions.first { $0.handle.map { "@" + $0 } == p.from }
            return Part(sender: p.from == "Mob" ? nil : s?.id ?? p.from, name: s.map { Collab.shortLabel($0) } ?? p.from, label: "", body: p.body, context: nil)
        }
    }

    var body: some View {
        let list = parts
        VStack(alignment: .leading, spacing: 12) {
            if list.isEmpty {
                Text(message.content).font(.footnote).foregroundStyle(.secondary).padding(.leading, 34)
            }
            ForEach(list, id: \.self) { p in
                if let sender = p.sender { line(p, sender) }
                else {
                    Label {
                        Text((p.context.map { "Request “\($0)”: " } ?? "") + p.body)
                    } icon: { Image(systemName: "info.circle") }
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func line(_ p: Part, _ sender: String) -> some View {
        let session = app.chat.sessions.first { $0.id == sender }
        let color = Color(hue: Collab.hue(sender), saturation: 0.6, brightness: 0.75)
        return HStack(alignment: .top, spacing: 10) {
            AgentAvatar(id: sender, label: p.name)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let session {
                        Button(p.name) { app.chat.open(session.id) }.font(.caption.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                            .accessibilityHint("Opens that conversation")
                    } else {
                        Text(p.name).font(.caption.weight(.semibold)).lineLimit(1)
                    }
                    if let r = runnerTitle(session?.runner) { Text(r).font(.caption2).foregroundStyle(.secondary) }
                    if !p.label.isEmpty { Text("· \(p.label)").font(.caption2).foregroundStyle(.secondary) }
                }
                MarkdownView(text: p.body)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2) }
                if let c = p.context { Text("Re: \(c)").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
    }
}

/// The user's text with @mentions of other conversations as chips; tapping one opens it.
struct MentionText: View {
    @Environment(AppState.self) private var app
    let text: String

    var body: some View {
        let segs = Collab.mentionSegments(text, sessions: app.chat.sessions, current: app.chat.currentId)
        var out = AttributedString()
        for seg in segs {
            var part = AttributedString(seg.text)
            if let id = seg.session {
                part.link = URL(string: "mob-agent:\(id)")
                part.font = .body.weight(.semibold)
                part.backgroundColor = .white.opacity(0.22)
                part.underlineStyle = .single
            }
            out += part
        }
        return Text(out)
            .tint(.white)
            .environment(\.openURL, OpenURLAction { url in
                guard url.scheme == "mob-agent" else { return .systemAction }
                app.chat.open(url.absoluteString.replacingOccurrences(of: "mob-agent:", with: ""))
                return .handled
            })
    }
}
