import SwiftUI
import UniformTypeIdentifiers

/// Files: the office computer's shared folder as one list, like the desktop's left pane. Folders
/// open (never above the shared folder); tapping a file downloads it into Mob's folder in the Files
/// app. Uploads go into the open folder. Folders themselves are not transferred on the phone.
struct FilesView: View {
    @Environment(AppState.self) private var app
    @State private var importing = false
    @State private var renaming: Entry?
    @State private var newName = ""
    @State private var deleting: Entry?
    private var files: FileTransferStore { app.files }
    private var enabled: Bool { app.health?.supports("fileTransfers") == true && app.activeMachine?.needsPairing != true }
    private var manage: Bool { app.health?.supports("fileFolders") == true }

    private struct Entry: Identifiable { let name: String; let folder: Bool; var id: String { (folder ? "d:" : "f:") + name } }

    var body: some View {
        NavigationStack {
            List {
                if app.activeMachine == nil {
                    Text("Add your office computer in Settings").foregroundStyle(.secondary)
                } else if !enabled {
                    Text("Update mobd to a version with file transfers, then reconnect.").foregroundStyle(.secondary)
                } else {
                    transfers
                    Section { entries } header: { breadcrumb }
                }
                if let error = files.error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Files")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { Task { await files.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(!enabled).accessibilityLabel("Refresh files")
                    Button { importing = true } label: { Image(systemName: "plus") }
                        .disabled(!enabled || files.preparing).accessibilityLabel("Upload files")
                }
            }
            .refreshable { if enabled { await files.refresh() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await files.importFiles(urls) }
                case .failure(let error): files.error = readable(error)
                }
            }
            .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName).autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { if let e = renaming { act { try await files.rename(e.name, to: newName.trimmingCharacters(in: .whitespaces)) } } }
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .confirmationDialog(deleting.map { "Delete \($0.name)\($0.folder ? " and everything in it" : "")?" } ?? "",
                                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete", role: .destructive) { if let e = deleting { act { try await files.delete(e.name) } } }
            } message: { Text("It is removed from the office computer and cannot be restored.") }
        }
        .task(id: "\(app.activeMachineId ?? ""):\(app.apiClient.baseURL):\(enabled)") {
            if enabled { await files.refresh() }
        }
    }

    private func act(_ work: @escaping () async throws -> Void) {
        Task { do { try await work() } catch { files.error = readable(error) } }
    }

    // MARK: Folder

    private var breadcrumb: some View {
        let parts = files.path.split(separator: "/").map(String.init)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                Button(files.listing.map { URL(fileURLWithPath: $0.directory).lastPathComponent } ?? "Shared folder") { Task { await files.open("") } }
                    .foregroundStyle(parts.isEmpty ? .primary : .secondary)
                ForEach(parts.indices, id: \.self) { i in
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                    Button(parts[i]) { Task { await files.open(parts[...i].joined(separator: "/")) } }
                        .foregroundStyle(i == parts.count - 1 ? .primary : .secondary)
                }
            }
            .font(.subheadline).textCase(nil).buttonStyle(.plain)
        }
    }

    @ViewBuilder private var entries: some View {
        if let listing = files.listing {
            ForEach(listing.folders ?? []) { folder in
                Button { Task { await files.open(joinRemote(files.path, folder.name)) } } label: {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(Color.accentColor)
                        Text(folder.name)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the folder")
                .modifier(Actions(entry: Entry(name: folder.name, folder: true), manage: manage, rename: startRename, delete: { deleting = $0 }, download: nil))
            }
            ForEach(listing.files) { file in
                Button { files.download(file) } label: {
                    HStack {
                        Text(file.name).lineLimit(2)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Downloads the file to Mob's folder in Files")
                .modifier(Actions(entry: Entry(name: file.name, folder: false), manage: manage, rename: startRename, delete: { deleting = $0 }, download: { files.download(file) }))
            }
            if listing.files.isEmpty && (listing.folders ?? []).isEmpty {
                Text(files.path.isEmpty ? "No files yet. Tap + to upload, or ask your agent to copy files here." : "This folder is empty.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func startRename(_ entry: Entry) { newName = entry.name; renaming = entry }

    private struct Actions: ViewModifier {
        let entry: Entry
        let manage: Bool
        let rename: (Entry) -> Void
        let delete: (Entry) -> Void
        let download: (() -> Void)?
        func body(content: Content) -> some View {
            content
                .contextMenu {
                    if let download { Button { download() } label: { Label("Download", systemImage: "arrow.down.circle") } }
                    if manage {
                        Button { rename(entry) } label: { Label("Rename…", systemImage: "pencil") }
                        Button(role: .destructive) { delete(entry) } label: { Label("Delete…", systemImage: "trash") }
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if manage {
                        Button(role: .destructive) { delete(entry) } label: { Label("Delete", systemImage: "trash") }
                        Button { rename(entry) } label: { Label("Rename", systemImage: "pencil") }.tint(.gray)
                    }
                }
        }
    }

    // MARK: Transfers

    /// Active transfers, then the most recent finished one. A finished upload goes after a few
    /// seconds; a finished download stays with Share until dismissed.
    @ViewBuilder private var transfers: some View {
        let mine = files.visibleTasks
        let active = mine.filter { $0.state != "done" }
        let recent = mine.filter { $0.state == "done" }.max { ($0.finishedAt ?? .distantPast) < ($1.finishedAt ?? .distantPast) }
        if !active.isEmpty || recent != nil {
            Section {
                ForEach(active) { task in TransferRow(task: task, files: files) }
                if let recent {
                    HStack {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.success)
                        Text("\(recent.upload ? "Uploaded" : "Downloaded") \(recent.name)").lineLimit(1)
                        Spacer()
                        if let path = recent.localPath { ShareLink(item: URL(fileURLWithPath: path)) { Image(systemName: "square.and.arrow.up") }.accessibilityLabel("Share \(recent.name)") }
                        Button { files.dismiss(recent.id) } label: { Image(systemName: "xmark") }.accessibilityLabel("Dismiss")
                    }
                    .buttonStyle(.borderless).font(.subheadline)
                    .task(id: recent.id) {
                        // Only one finished transfer shows: older ones go at once, a finished upload soon after.
                        for t in mine where t.state == "done" && t.id != recent.id { files.dismiss(t.id) }
                        if recent.upload { try? await Task.sleep(for: .seconds(4)); files.dismiss(recent.id) }
                    }
                }
            } footer: {
                if !active.isEmpty { Text("Transfers pause when Mob is in the background; tap Continue when you're back.") }
            }
        }
    }

    private struct TransferRow: View {
        let task: FileTransfer
        let files: FileTransferStore
        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: task.upload ? "arrow.up" : "arrow.down").foregroundStyle(.secondary)
                    Text(task.name).lineLimit(1)
                    Spacer()
                    if task.state == "running" || task.state == "queued" {
                        Button { files.pause(task.id) } label: { Image(systemName: "pause.fill") }.accessibilityLabel("Pause")
                    } else {
                        Button { files.start(task.id) } label: { Image(systemName: task.state == "failed" ? "arrow.clockwise" : "play.fill") }
                            .accessibilityLabel(task.state == "failed" ? "Retry" : "Continue")
                    }
                    Button(role: .destructive) { Task { await files.cancel(task) } } label: { Image(systemName: "xmark") }.accessibilityLabel("Cancel")
                }
                .buttonStyle(.borderless)
                ProgressView(value: Double(task.bytes), total: Double(max(1, task.size)))
                Text(status).font(.caption).foregroundStyle(task.state == "failed" ? .red : .secondary).lineLimit(2)
            }
        }
        private var status: String {
            let sizes = "\(ByteCountFormatter.string(fromByteCount: task.bytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: task.size, countStyle: .file))"
            switch task.state {
            case "failed": return task.message ?? "Failed"
            case "queued": return "Waiting · \(sizes)"
            case "paused": return "Paused · \(sizes)"
            default: return task.message ?? sizes
            }
        }
    }
}
