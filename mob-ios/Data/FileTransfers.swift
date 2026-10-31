import CryptoKit
import Foundation
import TUSKit

let fileChunkSize = 4 * 1024 * 1024

struct RemoteFile: Codable, Identifiable {
    let name: String
    let size: Int64
    let modified: String
    var id: String { name }
}

struct RemoteFolder: Codable, Identifiable {
    let name: String
    let modified: String
    var id: String { name }
}

struct FileListing: Decodable {
    let directory: String
    let maxUploadSize: Int64
    let files: [RemoteFile]
    /// Present when mobd has fileFolders.
    let folders: [RemoteFolder]?
}

/// Paths inside mobd's shared folder are "/"-separated; "" is the folder itself.
func joinRemote(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : "\(dir)/\(name)" }
func parentRemote(_ path: String) -> String { path.lastIndex(of: "/").map { String(path[..<$0]) } ?? "" }

/// mobd's URL for a shared path: each segment encoded on its own.
func remoteFileURL(_ api: APIClient, _ path: String) -> URL {
    path.split(separator: "/").reduce(api.url("files")) { $0.appendingPathComponent(String($1)) }
}

/// Moves a verified download into dir, never replacing a file: an existing name gets " (1)", " (2)"…
func placeDownload(_ source: URL, in dir: URL, name: String) throws -> URL {
    guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { throw transferError("Invalid file name") }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let ext = (name as NSString).pathExtension, stem = (name as NSString).deletingPathExtension
    for n in 0..<1000 {
        let candidate = n == 0 ? name : "\(stem) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
        let target = dir.appendingPathComponent(candidate)
        do { try FileManager.default.moveItem(at: source, to: target); return target }
        catch CocoaError.fileWriteFileExists { continue }
    }
    throw transferError("Too many files with that name")
}

struct FileTransfer: Codable, Identifiable {
    let id: String
    let machine: String
    let base: String
    let upload: Bool
    var name: String
    var size: Int64
    var sha256: String
    var bytes: Int64 = 0
    /// queued, running, paused, failed or done.
    var state = "paused"
    var uploadURL: URL?
    var etag: String?
    var message: String?
    /// Where the file is in mobd's shared folder; nil for transfers made before folders.
    var remotePath: String?
    /// A finished download: the file in Mob's Documents folder.
    var localPath: String?
    var finishedAt: Date?
}

struct FileReceipt: Decodable { let name: String; let size: Int64; let sha256: String }

func transferError(_ message: String) -> APIError { APIError(message: message, status: nil) }

func transferFailure(_ error: Error) -> Error {
    if let tus = error as? TUSClientError {
        switch tus {
        case .couldNotUploadFile(let underlying), .couldNotGetFileStatus(let underlying), .couldNotCreateFileOnServer(let underlying):
            return transferFailure(underlying)
        default: break
        }
    }
    if let api = error as? TUSAPIError {
        switch api {
        case .failedRequest(let response, _): return APIError(message: api.localizedDescription, status: response.statusCode)
        case .underlyingError(let underlying): return transferFailure(underlying)
        default: break
        }
    }
    return error
}

func validatedUploadURL(_ value: URL, base: URL) throws -> URL {
    let root = base.appendingPathComponent("file-uploads").path + "/"
    let id = String(value.path.dropFirst(root.count))
    guard value.scheme == base.scheme, value.host == base.host, value.port == base.port,
          value.path.hasPrefix(root), value.query == nil, value.fragment == nil,
          value.user == nil, value.password == nil, id.count == 32,
          id.allSatisfy({ "0123456789abcdef".contains($0) }) else {
        throw transferError("Invalid upload location returned by mobd")
    }
    return value
}

func checkDownloadRange(_ response: HTTPURLResponse, etag: String, start: Int64, end: Int64, size: Int64) throws {
    guard response.statusCode != 412, response.value(forHTTPHeaderField: "ETag") == etag else {
        throw transferError("Remote file changed. Cancel and download the new version.")
    }
    guard response.statusCode == 206,
          response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(end)/\(size)" else {
        throw transferError("Invalid download range returned by mobd")
    }
}

func transferDigest(_ url: URL) throws -> String {
    let file = try FileHandle(forReadingFrom: url)
    defer { try? file.close() }
    var hash = SHA256()
    while let data = try file.read(upToCount: 256 * 1024), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

final class NoTransferRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// The SDK only receives a pre-created, validated upload URL. Credentials live in the
/// session configuration so TUSKit never writes them into its upload metadata plist.
@MainActor
final class TusFileUpload: NSObject, TUSClientDelegate {
    private var client: TUSClient?
    private var session: URLSession?
    private var continuation: CheckedContinuation<Void, Error>?
    var progress: ((Int64) -> Void)?

    func run(file: URL, directory: URL, destination: URL, api: APIClient) async throws {
        _ = try validatedUploadURL(destination, base: api.baseURL)
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = api.token.map { ["Authorization": "Bearer \($0)"] }
        config.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: config, delegate: NoTransferRedirects(), delegateQueue: nil)
        self.session = session
        let tus = try TUSClient(server: destination, storageDirectory: directory, session: session,
                                chunkSize: fileChunkSize, supportedExtensions: [])
        self.client = tus
        tus.delegate = self
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                do {
                    let stored = try tus.getStoredUploads()
                    // Stored metadata is an input boundary too: never let a stale destination
                    // send this session's credential to a different server.
                    for item in stored {
                        if let remote = item.remoteDestination { _ = try validatedUploadURL(remote, base: api.baseURL) }
                    }
                    if stored.isEmpty { try tus.uploadFileAt(filePath: file, uploadURL: destination) }
                    else {
                        tus.start()
                        for id in try tus.failedUploadIDs() { try tus.retry(id: id) }
                    }
                } catch { finish(error) }
            }
        } onCancel: {
            Task { @MainActor in self.client?.stopAndCancelAll(); self.finish(CancellationError()) }
        }
    }

    private func finish(_ error: Error? = nil) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: transferFailure(error)) } else { continuation.resume() }
        session?.invalidateAndCancel()
    }

    nonisolated func didStartUpload(id: UUID, context: [String: String]?, client: TUSClient) {}
    nonisolated func didFinishUpload(id: UUID, url: URL, context: [String: String]?, client: TUSClient) {
        Task { @MainActor in self.finish() }
    }
    nonisolated func uploadFailed(id: UUID, error: Error, context: [String: String]?, client: TUSClient) {
        Task { @MainActor in self.finish(error) }
    }
    nonisolated func fileError(error: TUSClientError, client: TUSClient) { Task { @MainActor in self.finish(error) } }
    nonisolated func fileError(id: UUID?, error: TUSClientError, client: TUSClient) { Task { @MainActor in self.finish(error) } }
    nonisolated func totalProgress(bytesUploaded: Int, totalBytes: Int, client: TUSClient) {}
    nonisolated func progressFor(id: UUID, context: [String: String]?, bytesUploaded: Int, totalBytes: Int, client: TUSClient) {
        Task { @MainActor in self.progress?(Int64(bytesUploaded)) }
    }
}
