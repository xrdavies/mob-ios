import SwiftUI

struct ChatView: View {
    @Environment(AppState.self) private var app
    let openSettings: () -> Void
    @State private var showChats = false
    @State private var pairing: PairRequest?
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var chat: ChatStore { app.chat }

    private var items: [TimelineItem] {
        guard let d = chat.detail else { return [] }
        return buildTimeline(tasks: d.tasks, messages: d.session.messages ?? [], activities: d.activities, questions: d.questions)
    }

    /// The message being sent to the open chat (or to a new chat).
    private var outgoing: Outgoing? {
        guard let o = chat.outbox, o.sessionId == chat.currentId else { return nil }
        return o
    }

    var body: some View {
        // iPad: the chat list stays beside the chat instead of opening as a sheet.
        if sizeClass == .regular {
            NavigationSplitView {
                SessionList(openSettings: openSettings, sidebar: true)
            } detail: {
                chatStack
            }
        } else {
            chatStack
        }
    }

    private var chatStack: some View {
        @Bindable var app = app
        let items = items
        let lastFooter = items.last { if case .footer = $0 { return true } else { return false } }?.id
        return NavigationStack {
            GeometryReader { geo in
                // Wide screens show the desktop in a column beside the chat, like the desktop app.
                let side = geo.size.width >= 720
                HStack(spacing: 0) {
                    chatColumn(items, lastFooter: lastFooter, thumbnailOnTop: !side, width: min(geo.size.width, 840))
                    if side, app.showDesktopDrawer, app.activeMachine != nil {
                        Divider()
                        DesktopThumbnail(width: min(geo.size.width * 0.4, 520))
                            .frame(width: min(geo.size.width * 0.4, 520))
                            .frame(maxHeight: .infinity, alignment: .top)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if sizeClass != .regular {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showChats = true } label: {
                            Image(systemName: "sidebar.left")
                                .overlay(alignment: .topTrailing) {
                                    if app.waitingCount > 0 {
                                        Text("\(app.waitingCount)").font(.caption2.bold()).foregroundStyle(.white)
                                            .padding(.horizontal, 4).background(Color.red, in: Capsule()).offset(x: 9, y: -8)
                                    }
                                }
                        }
                        .accessibilityLabel(app.waitingCount > 0 ? "Chats, \(app.waitingCount) waiting for you" : "Chats")
                    }
                }
                ToolbarItem(placement: .principal) { title }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { chat.open(nil) } label: { Image(systemName: "square.and.pencil") }
                        .disabled(app.activeMachine == nil || chat.currentId == nil)
                        .accessibilityLabel("New chat")
                    Button {
                        withAnimation { app.showDesktopDrawer.toggle() }
                    } label: {
                        // Shown: the same icon, highlighted (a badged symbol read as a warning).
                        Image(systemName: "desktopcomputer")
                            .padding(5)
                            .background(app.showDesktopDrawer ? Color.accentColor.opacity(0.15) : .clear, in: Circle())
                    }
                    .disabled(app.activeMachine == nil)
                    .accessibilityLabel(app.showDesktopDrawer ? "Hide desktop" : "Show desktop")
                }
            }
            .sheet(isPresented: $showChats) { SessionList(openSettings: openSettings) }
            .sheet(item: $pairing) { PairingSheet(existing: $0.machine) }
            .onChange(of: showChats || pairing != nil, initial: true) { app.chatCovered = showChats || pairing != nil }
            .fullScreenCover(isPresented: $app.showLiveView) { LiveView() }
            .alert("Something went wrong", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(chat.error ?? "")
            }
        }
    }

    /// Timeline and composer, kept to a readable width on wide screens.
    private func chatColumn(_ items: [TimelineItem], lastFooter: String?, thumbnailOnTop: Bool, width: CGFloat) -> some View {
        VStack(spacing: 0) {
            RouteBanner()
            if let banner = app.desktops.visibleBanner { ResourceBannerView(banner: banner) }
            if thumbnailOnTop, app.showDesktopDrawer, app.activeMachine != nil {
                DesktopThumbnail(width: width)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            content(items, lastFooter: lastFooter)
        }
        .frame(maxWidth: 840)
        .frame(maxWidth: .infinity)
        .safeAreaInset(edge: .bottom) {
            if let machine = app.activeMachineId {
                Composer(draft: app.drafts.draft(machine: machine, session: chat.currentId))
                    .id("\(machine)/\(chat.currentId ?? "")")
                    .frame(maxWidth: 840)
            }
        }
    }

    private var title: some View {
        VStack(spacing: 1) {
            Text(chat.currentId == nil ? "New chat" : chat.detail?.session.displayTitle ?? "…")
                .font(.headline).lineLimit(1)
            HStack(spacing: 5) {
                Circle().fill(app.isConnected ? Color.success : .red).frame(width: 7, height: 7)
                if let m = app.activeMachine, m.addresses.count > 1, let a = m.address {
                    // Two ways to reach the Mac: show which one, and let the user switch here.
                    Menu {
                        RouteMenuItems(machine: m)
                    } label: {
                        Text("\(m.name) · via \(m.label(a))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                } else {
                    Text(app.activeMachine?.name ?? "No office Mac").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                if let waiting = app.queued[app.activeMachineId ?? ""], waiting > 0 {
                    Text("· queue \(waiting)").font(.caption).foregroundStyle(.secondary)
                }
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
        } else if let m = app.activeMachine, m.needsPairing {
            empty("This device needs to be paired again", "mobd on \(m.name) does not accept this device. Run mobd link on the office Mac, then pair with the new link or QR code.") {
                Button("Pair again") { pairing = PairRequest(machine: m) }.buttonStyle(.borderedProminent)
            }
        } else if chat.currentId == nil && outgoing == nil {
            empty("New chat on \(app.activeMachine?.name ?? "")", "Ask the agent to do something on the office Mac")
        } else if chat.detail == nil && chat.loading && outgoing == nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ChatTimeline(items: items, lastFooter: lastFooter, outgoing: outgoing)
                .id("\(app.activeMachineId ?? "")/\(chat.currentId ?? "")")
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

}

private struct ChatTimeline: View {
    @Environment(AppState.self) private var app
    let items: [TimelineItem]
    let lastFooter: String?
    let outgoing: Outgoing?
    @State private var atBottom = true

    var body: some View {
        let pendingQuestion = items.last {
            if case .ask(_, let q) = $0 { return q.isPending } else { return false }
        }?.id
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(items) { item in
                        TimelineRow(item: item, runner: app.chat.detail?.session.runner, last: item.id == lastFooter).id(item.id)
                    }
                    if let o = outgoing { OutgoingMessage(text: o.text).id("outbox") }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .modifier(ChatScrollPosition(atBottom: $atBottom))
            .accessibilityIdentifier("chatTimeline")
            .scrollDismissesKeyboard(.interactively)
            // The working row keeps its ID as replies grow; follow content only while at the bottom.
            .onChange(of: items) { if atBottom { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: outgoing) { if outgoing != nil { proxy.scrollTo("bottom", anchor: .bottom) } }
            .onChange(of: pendingQuestion) { if let pendingQuestion { proxy.scrollTo(pendingQuestion, anchor: .bottom) } }
        }
    }
}

private struct ChatScrollPosition: ViewModifier {
    @Binding var atBottom: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .defaultScrollAnchor(.bottom, for: .initialOffset)
                .defaultScrollAnchor(.top, for: .alignment)
                .defaultScrollAnchor(atBottom ? .bottom : .top, for: .sizeChanges)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    geometry.contentSize.height + geometry.contentInsets.bottom - geometry.visibleRect.maxY < 60
                } action: { _, bottom in atBottom = bottom }
        } else {
            // shortcut: iOS 17 has no scroll geometry callback; remove this fallback when targeting iOS 18.
            content.defaultScrollAnchor(.bottom)
        }
    }
}

/// Chat list for the active machine, with the machine switcher on top.
/// A sheet on iPhone; on iPad it is the `sidebar` of a split view and stays beside the chat.
struct SessionList: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Void
    var sidebar = false
    @State private var showArchived = false
    @State private var renaming: Session?
    @State private var newTitle = ""
    @State private var deleting: Session?
    @State private var confirmArchive: Session?
    @State private var confirmClose: Session?
    @State private var seedNotice: String?
    @State private var query = ""

    private var chat: ChatStore { app.chat }
    private var searching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Chats (including archived) whose title matches, and other machines to switch to.
    @ViewBuilder private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        let found = (chat.sessions + (chat.archived ?? [])).filter { seen.insert($0.id).inserted && $0.displayTitle.localizedCaseInsensitiveContains(q) }
        let machines = app.machines.filter { $0.id != app.activeMachineId && $0.name.localizedCaseInsensitiveContains(q) }
        Section(found.isEmpty ? "No chats match" : "Chats") { ForEach(found) { row($0) } }
        if !machines.isEmpty {
            Section("Machines") {
                ForEach(machines) { m in
                    Button { app.selectMachine(m.id); query = "" } label: { Label("Switch to \(m.name)", systemImage: "desktopcomputer") }
                }
            }
        }
    }

    var body: some View {
        if sidebar { list } else { NavigationStack { list } }
    }

    private var list: some View {
        List {
            Section {
                Button {
                    chat.open(nil)
                    close()
                } label: { Label("New chat", systemImage: "square.and.pencil") }
                .disabled(app.activeMachine == nil)
            }
            if searching {
                searchResults
            } else {
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
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search chats")
        // Search covers archived chats too, so load them once a search starts.
        .onChange(of: searching) { if searching { chat.loadArchived() } }
        .refreshable { chat.refreshSessions() }
        .navigationTitle("Chats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { machineMenu }
            if !sidebar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
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
            Text("Delete \"\(deleting?.displayTitle ?? "")\"?"),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { if let s = deleting { chat.delete(s) } }
        } message: {
            let extra = app.desktops.mark(deleting?.id ?? "") != nil ? " Its desktop closes; open windows are lost." : ""
            Text("The chat and its screenshots are removed from the office Mac. This cannot be undone.\(extra)")
        }
        .confirmationDialog(
            Text("Close desktop?"),
            isPresented: Binding(get: { confirmClose != nil }, set: { if !$0 { confirmClose = nil } }),
            titleVisibility: .visible
        ) {
            Button("Close desktop", role: .destructive) {
                if let s = confirmClose { app.desktops.close(s.id) { if let e = $0 { chat.error = e } } }
            }
        } message: {
            Text("The running turn will be stopped and open windows closed. Files and browser logins are kept.")
        }
        .confirmationDialog(
            Text("Archive \"\(confirmArchive?.displayTitle ?? "")\"?"),
            isPresented: Binding(get: { confirmArchive != nil }, set: { if !$0 { confirmArchive = nil } }),
            titleVisibility: .visible
        ) {
            Button("Archive") { if let s = confirmArchive { chat.setArchived(s, true) } }
        } message: {
            Text("Its desktop closes; open windows are lost.")
        }
        .alert(seedNotice ?? "", isPresented: Binding(get: { seedNotice != nil }, set: { if !$0 { seedNotice = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func close() { if !sidebar { dismiss() } }

    private var machineMenu: some View {
        Menu {
            ForEach(app.machines) { m in
                Button { app.selectMachine(m.id) } label: {
                    let title = m.name + ((app.queued[m.id] ?? 0) > 0 ? " · queue \(app.queued[m.id]!)" : "")
                    if m.id == app.activeMachineId { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if let m = app.activeMachine, m.addresses.count > 1 {
                Section("\(m.name) route") { RouteMenuItems(machine: m) }
            }
            Divider()
            Button {
                close()
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
            close()
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
            Button { archive(s, s.archived != true) } label: {
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
            if app.desktops.mark(s.id) != nil {
                Button { confirmClose = s } label: { Label("Close desktop", systemImage: "xmark.circle") }
                Button { seedDesktop(s.id) } label: { Label("Use this browser profile for new conversations", systemImage: "globe") }
            }
            Button { archive(s, s.archived != true) } label: {
                Label(s.archived == true ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
                .disabled(Status.busy(s.status))
        }
    }

    private func archive(_ s: Session, _ archived: Bool) {
        if archived && app.desktops.mark(s.id) != nil { confirmArchive = s }
        else { chat.setArchived(s, archived) }
    }

    private func seedDesktop(_ id: String) {
        app.desktops.seed(id) { error in
            seedNotice = error ?? "New conversations start with this conversation's browser logins."
        }
    }

    /// Waiting (needs you), running, queued, failed, or a plain chat bubble.
    @ViewBuilder private func statusIcon(_ s: Session) -> some View {
        if s.waiting == true { Circle().fill(Color.waiting).frame(width: 10, height: 10) }
        else if s.status == Status.running { ProgressView().controlSize(.small) }
        else if s.status == Status.queued { Image(systemName: "clock").foregroundStyle(.secondary) }
        else if s.status == Status.failed { Circle().fill(.red).frame(width: 10, height: 10) }
        else if let mark = app.desktops.mark(s.id) {
            Image(systemName: mark == .asleep ? "moon.fill" : "desktopcomputer")
                .foregroundStyle(mark == .asleep ? .secondary : Color.blue)
                .font(.caption)
                .accessibilityLabel(mark == .asleep ? "Desktop asleep" : "Desktop running")
        }
        else { Image(systemName: "bubble.left").foregroundStyle(.secondary) }
    }
}
