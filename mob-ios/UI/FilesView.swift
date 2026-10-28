import SwiftUI
import UniformTypeIdentifiers

struct FilesView: View {
    @Environment(AppState.self) private var app
    @State private var importing = false
    @State private var export: FileExport?
    private var enabled: Bool { app.health?.supports("fileTransfers") == true && app.activeMachine?.needsPairing == false }

    var body: some View {
        NavigationStack {
            List {
                if let machine = app.activeMachine {
                    Section {
                        Text(machine.name).font(.headline)
                        if !enabled { Text("Update mobd to a version with file transfers, then reconnect.").foregroundStyle(.secondary) }
                    }
                } else { Text("Add your office computer in Settings") }
                if let listing = app.files.listing {
                    Section("Remote directory") {
                        Text(listing.directory).font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy directory") { UIPasteboard.general.string = listing.directory }
                        Text("Ask your agent to copy files from other directories here to download them.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if enabled {
                    Section {
                        Button { importing = true } label: { Label(app.files.preparing ? "Preparing upload…" : "Upload file", systemImage: "arrow.up.doc") }
                            .disabled(app.files.preparing)
                        Text("Transfers pause in the background. Return here and tap Continue.").font(.caption).foregroundStyle(.secondary)
                    }
                    Section("Remote files") {
                        ForEach(app.files.listing?.files ?? []) { file in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(file.name)
                                    Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button { app.files.download(file) } label: { Image(systemName: "arrow.down.circle") }
                                    .accessibilityLabel("Download \(file.name)")
                            }
                        }
                        if app.files.listing?.files.isEmpty == true { Text("No files yet").foregroundStyle(.secondary) }
                    }
                }
                if let error = app.files.error { Section { Text(error).foregroundStyle(.red) } }
                if !app.files.visibleTasks.isEmpty {
                    Section("Transfers") {
                        ForEach(app.files.visibleTasks) { task in
                            VStack(alignment: .leading, spacing: 8) {
                                Label(task.name, systemImage: task.upload ? "arrow.up.doc" : "arrow.down.doc")
                                Text("\(ByteCountFormatter.string(fromByteCount: task.bytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: task.size, countStyle: .file)) · \(task.state == "ready" ? "Ready to save" : task.state)")
                                    .font(.caption).foregroundStyle(.secondary)
                                if task.state == "running" { ProgressView(value: Double(task.bytes), total: Double(max(1, task.size))).accessibilityLabel("Transfer progress") }
                                if let message = task.message { Text(message).font(.caption).foregroundStyle(task.state == "failed" ? .red : .secondary) }
                                HStack {
                                    if task.state == "running" { Button("Pause") { app.files.pause(task.id) } }
                                    if task.state == "paused" || task.state == "failed" { Button(task.state == "failed" ? "Retry" : "Continue") { app.files.start(task.id) }.disabled(!enabled) }
                                    if task.state == "ready" {
                                        Button("Save…") {
                                            do { export = FileExport(id: task.id, url: try app.files.exportURL(task)) }
                                            catch { app.files.error = readable(error) }
                                        }
                                    }
                                    Spacer()
                                    Button(task.state == "done" ? "Dismiss" : "Cancel", role: .destructive) { Task { await app.files.cancel(task) } }
                                }.buttonStyle(.borderless)
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Files")
            .toolbar { Button { Task { await app.files.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(!enabled).accessibilityLabel("Refresh files") }
            .refreshable { if enabled { await app.files.refresh() } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): Task { await app.files.importFile(url) }
                case .failure(let error): app.files.error = readable(error)
                }
            }
            .sheet(item: $export) { item in FileSavePicker(url: item.url) { app.files.saved(item.id); export = nil } }
        }
        .task(id: "\(app.activeMachineId ?? ""):\(app.apiClient.baseURL):\(enabled)") {
            if enabled { await app.files.refresh() }
        }
    }
}

private struct FileExport: Identifiable { let id: String; let url: URL }

private struct FileSavePicker: UIViewControllerRepresentable {
    let url: URL
    let saved: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(saved: saved) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let saved: () -> Void
        init(saved: @escaping () -> Void) { self.saved = saved }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { if !urls.isEmpty { saved() } }
    }
}
