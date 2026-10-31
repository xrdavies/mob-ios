import Foundation
import Observation

@MainActor @Observable
final class FileTransferStore {
    private(set) var tasks: [FileTransfer] = []
    private(set) var listing: FileListing?
    /// The open folder in mobd's shared folder; "" is the shared folder itself.
    private(set) var path = ""
    var error: String?
    var preparing = false
    var foreground = true
    var onUnauthorized: ((Error, APIClient) -> Void)?
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var machine = ""
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    private let root: URL
    /// Finished downloads; the Files app shows it as On My iPhone › Mob.
    let downloads: URL
    private let parallel = 2

    init(directory: URL? = nil, downloads: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FileTransfers", isDirectory: true)
        self.downloads = downloads ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let index = root.appendingPathComponent("tasks.json")
            if FileManager.default.fileExists(atPath: index.path) {
                tasks = try JSONDecoder().decode([FileTransfer].self, from: Data(contentsOf: index))
                tasks = tasks.filter { UUID(uuidString: $0.id) != nil }.map { var t = $0; if ["running", "queued", "ready"].contains(t.state) { t.state = "paused" }; return t }
            }
        } catch { self.error = readable(error) }
    }

    var visibleTasks: [FileTransfer] { tasks.filter { $0.machine == machine && $0.base == api?.baseURL.absoluteString } }
    private func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    private func payload(_ id: String) -> URL { folder(id).appendingPathComponent("payload") }
    private func persist() throws { try JSONEncoder().encode(tasks).write(to: root.appendingPathComponent("tasks.json"), options: .atomic) }
    private func change(_ id: String, _ edit: (inout FileTransfer) -> Void) throws {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        edit(&tasks[i]); try persist()
    }

    func attach(_ api: APIClient?, machine: String) {
        pauseAll(); self.api = api; self.machine = machine; listing = nil; path = ""
    }
    func pauseAll() {
        for task in running.values { task.cancel() }
        for t in tasks where t.state == "queued" { try? change(t.id) { $0.state = "paused" } }
    }
    func pause(_ id: String) {
        if let work = running[id] { work.cancel() } else { try? change(id) { if $0.state == "queued" { $0.state = "paused" } } }
    }

    func open(_ path: String) async { self.path = path; listing = nil; await refresh() }

    private func checked(_ response: URLResponse, data: Data = Data()) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw transferError("Invalid response from mobd") }
        guard (200..<300).contains(response.statusCode) else {
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw APIError(message: body?["error"] as? String ?? "HTTP \(response.statusCode)", status: response.statusCode)
        }
        return response
    }

    func refresh() async {
        guard let api else { return }
        do {
            let path = self.path
            let (data, response) = try await api.session.data(for: api.request(api.url("files", path.isEmpty ? [:] : ["path": path])))
            _ = try checked(response, data: data)
            let listing = try JSONDecoder().decode(FileListing.self, from: data)
            if self.api === api, self.path == path { self.listing = listing; self.error = nil }
        } catch { if self.api === api { self.error = readable(error); onUnauthorized?(error, api) } }
    }

    /// Uploads the picked files into the open folder.
    func importFiles(_ urls: [URL]) async { for url in urls { await importFile(url) } }

    func importFile(_ url: URL) async {
        guard let api else { return }
        let remotePath = joinRemote(path, url.lastPathComponent)
        let machine = self.machine
        preparing = true
        defer { preparing = false }
        let id = UUID().uuidString
        let target = payload(id)
        do {
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            let result = try await Task.detached { () -> (Int64, String) in
                // Coordinate with iCloud/other file providers while taking the private copy.
                var coordinationError: NSError?
                var copyError: Error?
                NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { source in
                    do {
                        let info = try source.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                        guard info.isRegularFile == true, let size = info.fileSize, size <= 20 * 1024 * 1024 * 1024 else { throw transferError("Choose a regular file up to 20 GiB") }
                        try FileManager.default.copyItem(at: source, to: target)
                    } catch { copyError = error }
                }
                if let e = coordinationError ?? copyError as NSError? { throw e }
                let size = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard size <= 20 * 1024 * 1024 * 1024 else { throw transferError("Maximum upload size is 20 GiB") }
                return (Int64(size), try transferDigest(target))
            }.value
            tasks.append(FileTransfer(id: id, machine: machine, base: api.baseURL.absoluteString, upload: true, name: url.lastPathComponent, size: result.0, sha256: result.1, remotePath: remotePath))
            try persist()
            if self.api === api { start(id) }
        } catch {
            tasks.removeAll { $0.id == id }
            try? FileManager.default.removeItem(at: folder(id))
            self.error = readable(error)
        }
    }

    func download(_ file: RemoteFile) {
        guard let api else { return }
        let id = UUID().uuidString
        do {
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true)
            try Data().write(to: payload(id))
            tasks.append(FileTransfer(id: id, machine: machine, base: api.baseURL.absoluteString, upload: false, name: file.name, size: file.size, sha256: "", remotePath: joinRemote(path, file.name)))
            try persist(); start(id)
        } catch { self.error = readable(error) }
    }

    /// Queues a transfer; at most two run at a time.
    func start(_ id: String) {
        guard foreground, running[id] == nil, let task = tasks.first(where: { $0.id == id }), task.state != "done" else { return }
        do { try change(id) { $0.state = "queued"; $0.message = nil } } catch { self.error = readable(error); return }
        pump()
    }

    private func pump() {
        guard foreground, let api else { return }
        for task in tasks where task.state == "queued" && running[task.id] == nil && running.count < parallel
            && task.machine == machine && task.base == api.baseURL.absoluteString { run(task, api: api) }
    }

    private func run(_ task: FileTransfer, api: APIClient) {
        let id = task.id
        do { try change(id) { $0.state = "running"; $0.message = nil } } catch { self.error = readable(error); return }
        running[id] = Task {
            defer { running[id] = nil; pump() }
            do {
                if task.upload { try await upload(task, api: api) }
                else { try await receive(task, api: api) }
            } catch {
                let paused = Task.isCancelled
                do { try change(id) { if $0.state != "done" { $0.state = paused ? "paused" : "failed" }; $0.message = paused ? nil : readable(error) } }
                catch { self.error = readable(error) }
                if !paused { onUnauthorized?(error, api) }
            }
        }
    }

    private func upload(_ task: FileTransfer, api: APIClient) async throws {
        let local = payload(task.id)
        var destination = task.uploadURL
        if destination == nil {
            var req = api.request(api.url("file-uploads/"), method: "POST")
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue(String(task.size), forHTTPHeaderField: "Upload-Length")
            var metadata = "filename \(Data(task.name.utf8).base64EncodedString()),sha256 \(Data(task.sha256.utf8).base64EncodedString())"
            // A file in a folder names its place; older mobd takes only a file name at the top.
            if let rel = task.remotePath, rel.contains("/") { metadata += ",relativePath \(Data(rel.utf8).base64EncodedString())" }
            req.setValue(metadata, forHTTPHeaderField: "Upload-Metadata")
            let (data, response) = try await api.session.data(for: req)
            let http = try checked(response, data: data)
            guard let location = http.value(forHTTPHeaderField: "Location"), let url = URL(string: location, relativeTo: api.baseURL)?.absoluteURL else { throw transferError("Missing upload location") }
            destination = try validatedUploadURL(url, base: api.baseURL)
            try change(task.id) { $0.uploadURL = destination }
        }
        let url = try validatedUploadURL(destination!, base: api.baseURL)
        // Completion is idempotent, including a response lost before the previous app exited.
        var completion = api.request(url.appendingPathComponent("complete"), method: "POST")
        completion.timeoutInterval = 600
        let (previous, previousResponse) = try await api.session.data(for: completion)
        if (previousResponse as? HTTPURLResponse)?.statusCode == 200 {
            try await uploaded(task, data: previous); return
        }
        if (previousResponse as? HTTPURLResponse)?.statusCode != 409 { _ = try checked(previousResponse, data: previous) }
        let digest = try await Task.detached { try transferDigest(local) }.value
        guard digest == task.sha256 else { throw transferError("Local upload copy changed. Cancel and select the file again.") }
        try Task.checkCancellation()
        let tus = TusFileUpload()
        tus.progress = { [weak self] bytes in
            guard let self, let i = self.tasks.firstIndex(where: { $0.id == task.id }), self.tasks[i].state == "running" else { return }
            self.tasks[i].bytes = min(bytes, task.size)
        }
        try await tus.run(file: local, directory: folder(task.id).appendingPathComponent("tus"), destination: url, api: api)
        try Task.checkCancellation()
        try change(task.id) { $0.bytes = task.size; $0.message = "Verifying upload…" }
        let (data, response) = try await api.session.data(for: completion)
        _ = try checked(response, data: data)
        try await uploaded(task, data: data)
    }

    private func uploaded(_ task: FileTransfer, data: Data) async throws {
        let receipt = try JSONDecoder().decode(FileReceipt.self, from: data)
        guard receipt.sha256 == task.sha256, receipt.size == task.size else { throw transferError("Upload verification failed") }
        try change(task.id) {
            $0.state = "done"; $0.bytes = task.size; $0.remotePath = receipt.name
            $0.name = String(receipt.name.split(separator: "/").last ?? Substring(receipt.name)); $0.message = nil; $0.finishedAt = Date()
        }
        try FileManager.default.removeItem(at: folder(task.id))
        await refresh()
    }

    private func receive(_ task: FileTransfer, api: APIClient) async throws {
        let url = remoteFileURL(api, task.remotePath ?? task.name)
        var head = api.request(url, method: "HEAD")
        head.timeoutInterval = 600 // The first request hashes the remote file before serving it.
        let (data, response) = try await api.session.data(for: head)
        let http = try checked(response, data: data)
        guard let length = http.value(forHTTPHeaderField: "Content-Length"), let size = Int64(length), size >= 0,
              let etag = http.value(forHTTPHeaderField: "ETag"), let sha = http.value(forHTTPHeaderField: "X-Content-SHA256"),
              sha.count == 64, sha.allSatisfy({ "0123456789abcdef".contains($0) }) else { throw transferError("Invalid file information from mobd") }
        let file = try FileHandle(forWritingTo: payload(task.id))
        defer { try? file.close() }
        var offset = Int64(try file.seekToEnd())
        guard (task.etag == nil || task.etag == etag), offset <= size, offset == 0 || task.etag != nil else { throw transferError("Remote file changed. Cancel and download the new version.") }
        try change(task.id) { $0.size = size; $0.etag = etag; $0.sha256 = sha; $0.bytes = offset }
        while offset < size {
            try Task.checkCancellation()
            let end = min(offset + Int64(fileChunkSize), size) - 1
            var req = api.request(url)
            req.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
            req.setValue(etag, forHTTPHeaderField: "If-Match")
            let (temp, response) = try await api.session.download(for: req)
            defer { try? FileManager.default.removeItem(at: temp) }
            let http = try checked(response)
            try checkDownloadRange(http, etag: etag, start: offset, end: end, size: size)
            let bytes = try Data(contentsOf: temp, options: .mappedIfSafe)
            guard bytes.count == end - offset + 1 else { throw transferError("Incomplete download chunk; retry to continue") }
            try Task.checkCancellation()
            try file.write(contentsOf: bytes); try file.synchronize()
            offset += Int64(bytes.count)
            try change(task.id) { $0.bytes = offset }
        }
        try change(task.id) { $0.message = "Verifying download…" }
        let local = payload(task.id)
        let digest = try await Task.detached { try transferDigest(local) }.value
        guard digest == sha else { throw transferError("Download checksum mismatch. Cancel and download again.") }
        try Task.checkCancellation()
        let saved = try placeDownload(local, in: downloads, name: task.name)
        try? FileManager.default.removeItem(at: folder(task.id))
        try change(task.id) { $0.state = "done"; $0.localPath = saved.path; $0.message = nil; $0.finishedAt = Date() }
    }

    func cancel(_ task: FileTransfer) async {
        guard let api, task.machine == machine, task.base == api.baseURL.absoluteString else { return }
        running[task.id]?.cancel()
        await running[task.id]?.value
        do {
            let current = tasks.first(where: { $0.id == task.id })
            if task.upload, current?.state != "done", let url = current?.uploadURL {
                _ = try validatedUploadURL(url, base: api.baseURL)
                var req = api.request(url, method: "DELETE"); req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
                let (data, response) = try await api.session.data(for: req)
                if let http = response as? HTTPURLResponse, http.statusCode != 404 && http.statusCode != 410 { _ = try checked(response, data: data) }
            }
            if FileManager.default.fileExists(atPath: folder(task.id).path) { try FileManager.default.removeItem(at: folder(task.id)) }
            tasks.removeAll { $0.id == task.id }; try persist()
        } catch { self.error = readable(error) }
    }

    /// Removes a finished transfer from the list.
    func dismiss(_ id: String) {
        guard tasks.contains(where: { $0.id == id && $0.state == "done" }) else { return }
        tasks.removeAll { $0.id == id }; try? persist()
    }

    func rename(_ name: String, to newName: String) async throws {
        guard let api else { return }
        try await remote(remoteFileURL(api, joinRemote(path, name)).appendingPathComponent("rename"), "POST", ["newName": newName])
    }

    func delete(_ name: String) async throws {
        guard let api else { return }
        try await remote(remoteFileURL(api, joinRemote(path, name)), "DELETE")
    }

    private func remote(_ url: URL, _ method: String, _ body: [String: String]? = nil) async throws {
        guard let api else { return }
        var req = api.request(url, method: method)
        if let body { req.httpBody = try JSONEncoder().encode(body); req.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await api.session.data(for: req)
            _ = try checked(response, data: data)
        } catch { onUnauthorized?(error, api); throw error }
        await refresh()
    }
}
