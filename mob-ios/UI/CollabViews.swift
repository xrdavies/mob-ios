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

/// Set, change or clear the conversation's handle. Moving one from another conversation asks first.
struct HandleSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let session: Session
    @State private var text: String
    @State private var error: String?
    @State private var confirmMove: String?
    @State private var saving = false

    init(session: Session) {
        self.session = session
        _text = State(initialValue: session.handle ?? "")
    }

    private var handle: String { text.trimmingCharacters(in: .whitespaces).lowercased() }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("api", text: $text)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("handle-field")
                } header: {
                    Text("Handle")
                } footer: {
                    Text("The name other agents use to ask this one, e.g. @api. Lowercase letters, digits and -, starting with a letter, 2–32 characters. The title keeps describing the work.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Handle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(take: false) }.disabled(saving || (handle != "" && !Handle.isValid(handle)))
                }
            }
            .alert(
                "Give @\(confirmMove ?? "") to this conversation?",
                isPresented: Binding(get: { confirmMove != nil }, set: { if !$0 { confirmMove = nil } })
            ) {
                Button("Give") { save(take: true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It is taken from the conversation that has it now, which keeps no handle.")
            }
        }
        .presentationDetents([.medium])
    }

    private func save(take: Bool) {
        saving = true
        app.chat.setHandle(session, handle, take: take) { e in
            saving = false
            if let e, e.status == 409 {
                // Ask before taking it from another conversation.
                confirmMove = handle
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

/// The "@" picker above the composer: handles first, then titles. Archived agents are greyed out.
struct MentionPicker: View {
    let candidates: [MentionCandidate]
    let onPick: (MentionCandidate) -> Void
    let onSuggest: (Session) -> Void

    var body: some View {
        if !candidates.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { c in
                        Button { onPick(c) } label: {
                            HStack {
                                Text(c.label).lineLimit(1)
                                Spacer()
                                if c.archived { Text("archived").font(.caption).foregroundStyle(.secondary) }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(c.archived)
                        .foregroundStyle(c.archived ? .secondary : .primary)
                        .accessibilityHint(c.archived ? "Archived. Unarchive it to mention it." : "")
                        if c.session.handle == nil, !c.archived {
                            Button("Give it a handle…") { onSuggest(c.session) }
                                .font(.caption).padding(.horizontal, 12).padding(.bottom, 8)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
