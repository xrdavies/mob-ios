import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    let openSettings: () -> Void
    @State private var showChats = false

    private var chat: ChatStore { app.chat }

    private var items: [TimelineItem] {
        guard let d = chat.detail else { return [] }
        return buildTimeline(tasks: d.tasks, messages: d.session.messages ?? [], activities: d.activities, questions: d.questions)
    }

    var body: some View {
        @Bindable var app = app
        let items = items
        let lastFooter = items.last { if case .footer = $0 { return true } else { return false } }?.id
        NavigationStack {
            VStack(spacing: 0) {
                if app.showDesktopDrawer, app.activeMachine != nil {
                    DesktopThumbnail()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                content(items, lastFooter: lastFooter)
            }
            .safeAreaInset(edge: .bottom) {
                if app.activeMachine != nil { Composer() }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showChats = true } label: { Image(systemName: "sidebar.left") }
                        .accessibilityLabel("Chats")
                }
                ToolbarItem(placement: .principal) { title }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { chat.open(nil) } label: { Image(systemName: "square.and.pencil") }
                        .disabled(app.activeMachine == nil || chat.currentId == nil)
                        .accessibilityLabel("New chat")
                    Button {
                        withAnimation { app.showDesktopDrawer.toggle() }
                    } label: {
                        Image(systemName: app.showDesktopDrawer ? "desktopcomputer.trianglebadge.exclamationmark" : "desktopcomputer")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .disabled(app.activeMachine == nil)
                    .accessibilityLabel(app.showDesktopDrawer ? "Hide desktop" : "Show desktop")
                }
            }
            .sheet(isPresented: $showChats) { SessionList(openSettings: openSettings) }
            .fullScreenCover(isPresented: $app.showLiveView) { LiveView() }
            .alert("Something went wrong", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(chat.error ?? "")
            }
        }
    }

    private var title: some View {
        VStack(spacing: 1) {
            Text(chat.currentId == nil ? "New chat" : chat.detail?.session.displayTitle ?? "…")
                .font(.headline).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(app.isConnected ? Color.success : .red).frame(width: 7, height: 7)
                Text(app.activeMachine?.name ?? "No office Mac").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                let problems = app.health?.problems ?? []
                if app.isConnected && !problems.isEmpty {
                    Button("· \(problems.count) setup issue\(problems.count > 1 ? "s" : "")", action: openSettings)
                        .font(.caption).foregroundStyle(Color.waiting)
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ items: [TimelineItem], lastFooter: String?) -> some View {
        if app.activeMachine == nil {
            empty("Add your office Mac to start", "Settings → Machines → Add machine") {
                Button("Open Settings", action: openSettings).buttonStyle(.borderedProminent)
            }
        } else if chat.currentId == nil {
            empty("New chat on \(app.activeMachine?.name ?? "")", "Ask the agent to do something on the office Mac")
        } else if chat.detail == nil && chat.loading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            timeline(items, lastFooter: lastFooter)
        }
    }

    private func empty(_ title: String, _ hint: String, @ViewBuilder action: () -> some View = { EmptyView() }) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline)
            Text(hint).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            action().padding(.top, 8)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func timeline(_ items: [TimelineItem], lastFooter: String?) -> some View {
        let pendingQuestion = items.last {
            if case .ask(_, let q) = $0 { return q.isPending } else { return false }
        }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        TimelineRow(item: item, runner: chat.detail?.session.runner, last: item.id == lastFooter).id(item.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            // Follow new output; a new question always comes into view.
            .onChange(of: items.last?.id) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: pendingQuestion) { if pendingQuestion != nil { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } } }
            .onChange(of: chat.currentId) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

/// Chat list for the active machine, with the machine switcher on top.
struct SessionList: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Void
    @State private var showArchived = false
    @State private var renaming: Session?
    @State private var newTitle = ""
    @State private var deleting: Session?

    private var chat: ChatStore { app.chat }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        chat.open(nil)
                        dismiss()
                    } label: { Label("New chat", systemImage: "square.and.pencil") }
                    .disabled(app.activeMachine == nil)
                }
                let pinned = chat.sessions.filter { $0.pinned == true }
                if !pinned.isEmpty {
                    Section("Pinned") { ForEach(pinned) { row($0) } }
                }
                Section("Recent") {
                    let recent = chat.sessions.filter { $0.pinned != true }
                    if recent.isEmpty { Text("No chats yet").foregroundStyle(.secondary) }
                    ForEach(recent) { row($0) }
                }
                Section {
                    DisclosureGroup("Archived", isExpanded: $showArchived) {
                        let archived = chat.archived ?? []
                        if archived.isEmpty { Text("Nothing archived").foregroundStyle(.secondary) }
                        ForEach(archived) { row($0) }
                    }
                    .onChange(of: showArchived) { if showArchived { chat.loadArchived() } }
                }
            }
            .refreshable { chat.refreshSessions() }
            .navigationTitle("Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { machineMenu }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert("Rename chat", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $newTitle)
                Button("Rename") {
                    if let s = renaming, !newTitle.trimmingCharacters(in: .whitespaces).isEmpty {
                        chat.rename(s, newTitle.trimmingCharacters(in: .whitespaces))
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog(
                "Delete “\(deleting?.displayTitle ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { if let s = deleting { chat.delete(s) } }
            } message: {
                Text("The chat and its screenshots are removed from the office Mac. This cannot be undone.")
            }
        }
    }

    private var machineMenu: some View {
        Menu {
            ForEach(app.machines) { m in
                Button { app.selectMachine(m.id) } label: {
                    if m.id == app.activeMachineId { Label(m.name, systemImage: "checkmark") } else { Text(m.name) }
                }
            }
            Divider()
            Button {
                dismiss()
                openSettings()
            } label: { Label("Manage machines…", systemImage: "gearshape") }
        } label: {
            HStack(spacing: 5) {
                Circle().fill(app.isConnected ? Color.success : .red).frame(width: 7, height: 7)
                Text(app.activeMachine?.name ?? "No office Mac").lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }
        }
    }

    private func row(_ s: Session) -> some View {
        Button {
            chat.open(s.id)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                statusIcon(s).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.displayTitle).lineLimit(1)
                        .fontWeight(s.id == chat.currentId ? .semibold : .regular)
                        .foregroundStyle(.primary)
                    Text([s.runner, relativeTime(s.updatedAt)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if !Status.busy(s.status) {
                Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
            }
            Button { chat.setArchived(s, s.archived != true) } label: {
                Label(s.archived == true ? "Unarchive" : "Archive", systemImage: s.archived == true ? "tray.and.arrow.up" : "archivebox")
            }
            .tint(.indigo)
        }
        .swipeActions(edge: .leading) {
            if s.archived != true {
                Button { chat.setPinned(s, s.pinned != true) } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: "pin") }
                    .tint(.orange)
            }
        }
        .contextMenu {
            Button { newTitle = s.title ?? ""; renaming = s } label: { Label("Rename", systemImage: "pencil") }
            if s.archived != true {
                Button { chat.setPinned(s, s.pinned != true) } label: { Label(s.pinned == true ? "Unpin" : "Pin", systemImage: "pin") }
            }
            Button { chat.setArchived(s, s.archived != true) } label: {
                Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
                .disabled(Status.busy(s.status))
        }
    }

    /// Waiting (needs you), running, queued, failed, or a plain chat bubble.
    @ViewBuilder private func statusIcon(_ s: Session) -> some View {
        if s.waiting == true { Circle().fill(Color.waiting).frame(width: 10, height: 10) }
        else if s.status == Status.running { ProgressView().controlSize(.small) }
        else if s.status == Status.queued { Image(systemName: "clock").foregroundStyle(.secondary) }
        else if s.status == Status.failed { Circle().fill(.red).frame(width: 10, height: 10) }
        else { Image(systemName: "bubble.left").foregroundStyle(.secondary) }
    }
}
