import XCTest
import TUSKit
@testable import mob_ios

final class FileTransferTests: XCTestCase {
    func testTusAuthenticationFailureUsesExistingPairAgainFlow() {
        let response = HTTPURLResponse(url: URL(string: "https://office.example/")!, statusCode: 401, httpVersion: nil, headerFields: [:])!
        let error = TUSClientError.couldNotUploadFile(underlyingError: TUSAPIError.failedRequest(response, nil))
        XCTAssertTrue(transferFailure(error).isUnauthorized)
    }
    @MainActor
    func testRealMobdResumeUploadAndDownload() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["MOB_FILE_TEST_URL"], let token = env["MOB_FILE_TEST_TOKEN"] else { throw XCTSkip("Run against the isolated mobd file fixture") }
        let api = APIClient(baseURL: base, token: token)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("iOS 报告 \(UUID().uuidString).bin")
        let content = Data((0..<(17 * 1024 * 1024 + 17)).map { UInt8($0 % 251) })
        try content.write(to: source)
        let cache = dir.appendingPathComponent("cache"), saved = dir.appendingPathComponent("Documents")
        var store = FileTransferStore(directory: cache, downloads: saved)
        store.attach(api, machine: "fixture")
        await store.importFile(source)
        let uploadID = try XCTUnwrap(store.tasks.first?.id, store.error ?? "No upload task")
        try await waitFile("first upload chunk") { store.tasks.first?.bytes ?? 0 > 0 || store.tasks.first?.state == "failed" }
        store.pause(uploadID)
        try await waitFile("upload paused") { store.tasks.first?.state != "running" }
        XCTAssertEqual(store.tasks.first?.state, "paused", store.tasks.first?.message ?? "")
        let storedJSON = try String(contentsOf: cache.appendingPathComponent("tasks.json"), encoding: .utf8)
        XCTAssertFalse(storedJSON.contains(token))
        store = FileTransferStore(directory: cache, downloads: saved)
        store.attach(api, machine: "fixture")
        store.start(uploadID)
        try await waitFile("resumed upload") { store.tasks.first?.state != "running" }
        XCTAssertEqual(store.tasks.first?.state, "done", store.tasks.first?.message ?? "")
        await store.refresh()
        let remote = try XCTUnwrap(store.listing?.files.first(where: { $0.name == store.tasks.first?.name }))
        store.download(remote)
        let downloadID = try XCTUnwrap(store.tasks.last?.id)
        try await waitFile("first download chunk") { store.tasks.last?.bytes ?? 0 > 0 || store.tasks.last?.state == "failed" }
        store.pause(downloadID)
        try await waitFile("download paused") { store.tasks.last?.state != "running" }
        XCTAssertEqual(store.tasks.last?.state, "paused", store.tasks.last?.message ?? "")
        store = FileTransferStore(directory: cache, downloads: saved)
        store.attach(api, machine: "fixture")
        store.start(downloadID)
        try await waitFile("resumed download") { store.tasks.last?.state != "running" }
        let downloaded = try XCTUnwrap(store.tasks.last)
        XCTAssertEqual(downloaded.state, "done", downloaded.message ?? "")
        let local = URL(fileURLWithPath: try XCTUnwrap(downloaded.localPath))
        XCTAssertEqual(local.deletingLastPathComponent().standardizedFileURL, saved.standardizedFileURL)
        XCTAssertEqual(try transferDigest(local), try transferDigest(source))
        // A second download of the same file never replaces the first.
        store.download(remote)
        try await waitFile("second download") { store.tasks.last?.state == "done" || store.tasks.last?.state == "failed" }
        XCTAssertEqual(URL(fileURLWithPath: try XCTUnwrap(store.tasks.last?.localPath)).lastPathComponent,
                       (remote.name as NSString).deletingPathExtension + " (1).bin")
        XCTAssertEqual(try transferDigest(local), try transferDigest(source))
        // Zero-byte files exercise completion without sending PATCH data.
        let empty = dir.appendingPathComponent("empty-\(UUID().uuidString).txt")
        try Data().write(to: empty)
        await store.importFile(empty)
        try await waitFile("empty upload") { store.tasks.last?.state != "running" }
        XCTAssertEqual(store.tasks.last?.state, "done", store.tasks.last?.message ?? "")
        // Folders: upload into a subfolder, list it, download from it, rename and delete it.
        guard try await supportsFolders(api) else { return }
        let folder = "iOS 文件夹 \(UUID().uuidString)"
        await store.refresh()
        try await createFolder(api, folder)
        await store.open(folder)
        XCTAssertEqual(store.path, folder)
        let inner = dir.appendingPathComponent("inner.txt")
        try Data("inside".utf8).write(to: inner)
        await store.importFiles([inner])
        try await waitFile("upload into a folder") { store.tasks.last?.state == "done" || store.tasks.last?.state == "failed" }
        XCTAssertEqual(store.tasks.last?.remotePath, "\(folder)/inner.txt", store.tasks.last?.message ?? "")
        await store.refresh()
        let nested = try XCTUnwrap(store.listing?.files.first { $0.name == "inner.txt" })
        store.download(nested)
        try await waitFile("download from a folder") { store.tasks.last?.state == "done" || store.tasks.last?.state == "failed" }
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(store.tasks.last?.localPath))), Data("inside".utf8))
        try await store.rename("inner.txt", to: "renamed.txt")
        XCTAssertEqual(store.listing?.files.map(\.name), ["renamed.txt"])
        await store.open("")
        XCTAssertTrue(store.listing?.folders?.contains { $0.name == folder } == true)
        try await store.delete(folder)
        XCTAssertFalse(store.listing?.folders?.contains { $0.name == folder } == true)
    }

    private func supportsFolders(_ api: APIClient) async throws -> Bool {
        let (data, _) = try await api.session.data(for: api.request(api.url("health")))
        return ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["features"] as? [String])?.contains("fileFolders") == true
    }

    private func createFolder(_ api: APIClient, _ path: String) async throws {
        var req = api.request(api.url("file-folders"), method: "POST")
        req.httpBody = try JSONEncoder().encode(["path": path])
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await api.session.data(for: req)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 204)
    }

    @MainActor private func waitFile(_ label: String, _ done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(60)
        while !done() {
            if Date() > deadline { XCTFail("Timed out: \(label)"); throw transferError(label) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testUploadLocationsStayInsidePairedServer() throws {
        let base = URL(string: "https://office.example/")!
        let path = "/file-uploads/" + String(repeating: "a", count: 32)
        XCTAssertEqual(try validatedUploadURL(URL(string: "https://office.example" + path)!, base: base).path, path)
        for value in ["https://attacker.example" + path, "https://office.example/settings", "http://office.example" + path, "https://office.example" + path + "?token=bad"] {
            XCTAssertThrowsError(try validatedUploadURL(URL(string: value)!, base: base))
        }
    }

    func testRangeRejectsFullOrChangedRepresentation() throws {
        let url = URL(string: "https://office.example/files/a")!
        let good = ["ETag": "\"v1\"", "Content-Range": "bytes 4-7/8"]
        try checkDownloadRange(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: good)!, etag: "\"v1\"", start: 4, end: 7, size: 8)
        XCTAssertThrowsError(try checkDownloadRange(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: good)!, etag: "\"v1\"", start: 4, end: 7, size: 8))
        XCTAssertThrowsError(try checkDownloadRange(HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil, headerFields: good)!, etag: "\"v2\"", start: 4, end: 7, size: 8))
    }
}
