import Foundation
import Observation

@MainActor @Observable
final class FileTransferStore {
    private(set) var tasks: [FileTransfer] = []
    private(set) var listing: FileListing?
    var error: String?
    var preparing = false
    var foreground = true
    var onUnauthorized: ((Error, APIClient) -> Void)?
    @ObservationIgnored private var api: APIClient?
    @ObservationIgnored private var machine = ""
    @ObservationIgnored private var running: [String: Task<Void, Never>] = [:]
    private let root: URL

    init(directory: URL? = nil) {
        root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FileTransfers", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var excluded = root
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let index = root.appendingPathComponent("tasks.json")
            if FileManager.default.fileExists(atPath: index.path) {
                tasks = try JSONDecoder().decode([FileTransfer].self, from: Data(contentsOf: index))
                tasks = tasks.filter { UUID(uuidString: $0.id) != nil }.map { var t = $0; if t.state == "running" { t.state = "paused" }; return t }
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
        pauseAll(); self.api = api; self.machine = machine; listing = nil
    }
    func pauseAll() { for task in running.values { task.cancel() } }
    func pause(_ id: String) { running[id]?.cancel() }

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
            let (data, response) = try await api.session.data(for: api.request(api.url("files")))
            _ = try checked(response, data: data)
            let listing = try JSONDecoder().decode(FileListing.self, from: data)
            if self.api === api { self.listing = listing; self.error = nil }
        } catch { if self.api === api { self.error = readable(error); onUnauthorized?(error, api) } }
    }

    func importFile(_ url: URL) async {
        guard let api else { return }
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
            tasks.append(FileTransfer(id: id, machine: machine, base: api.baseURL.absoluteString, upload: true, name: url.lastPathComponent, size: result.0, sha256: result.1))
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
            tasks.append(FileTransfer(id: id, machine: machine, base: api.baseURL.absoluteString, upload: false, name: file.name, size: file.size, sha256: ""))
            try persist(); start(id)
        } catch { self.error = readable(error) }
    }

    func start(_ id: String) {
        guard foreground, running[id] == nil, let api, let task = tasks.first(where: { $0.id == id }),
              task.machine == machine, task.base == api.baseURL.absoluteString,
              task.state != "ready", task.state != "done" else { return }
        do { try change(id) { $0.state = "running"; $0.message = nil } } catch { self.error = readable(error); return }
        running[id] = Task {
            defer { running[id] = nil }
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
            req.setValue("filename \(Data(task.name.utf8).base64EncodedString()),sha256 \(Data(task.sha256.utf8).base64EncodedString())", forHTTPHeaderField: "Upload-Metadata")
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
        try change(task.id) { $0.state = "done"; $0.bytes = task.size; $0.name = receipt.name; $0.message = nil }
        try FileManager.default.removeItem(at: folder(task.id))
        await refresh()
    }

    private func receive(_ task: FileTransfer, api: APIClient) async throws {
        let url = api.url("files").appendingPathComponent(task.name)
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
        try change(task.id) { $0.state = "ready"; $0.message = nil }
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

    func exportURL(_ task: FileTransfer) throws -> URL {
        guard task.state == "ready", !task.name.contains("/"), !task.name.contains("\\"), task.name != ".", task.name != ".." else { throw transferError("File is not ready to save") }
        let dir = folder(task.id).appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(task.name)
        if !FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.copyItem(at: payload(task.id), to: dest) }
        return dest
    }

    func saved(_ id: String) {
        do { try change(id) { $0.state = "done" }; try FileManager.default.removeItem(at: folder(id)) }
        catch { self.error = readable(error) }
    }
}
