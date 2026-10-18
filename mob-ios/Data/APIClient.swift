import Foundation
import UIKit

/// A failure with a message the user can read (mobd answers errors as {"error": "..."}).
struct APIError: LocalizedError {
    let message: String
    let status: Int?
    var errorDescription: String? { message }
    /// mobd no longer accepts this device's token.
    var isUnauthorized: Bool { status == 401 }
}

extension Error {
    var isUnauthorized: Bool { (self as? APIError)?.isUnauthorized == true }
}

/// A readable message for any request failure.
func readable(_ error: Error) -> String {
    if let e = error as? APIError { return e.isUnauthorized ? "This device needs to be paired again" : e.message }
    if let e = error as? URLError {
        switch e.code {
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet: return "Cannot reach mobd"
        case .timedOut: return "mobd did not answer in time"
        default: break
        }
    }
    return error.localizedDescription
}

/// HTTP client for one mobd.
final class APIClient {
    let baseURL: URL
    /// Sent as "Authorization: Bearer …" on every request; nil before pairing.
    let token: String?
    let session: URLSession
    /// For event streams: an idle stream sends nothing, so it must not time out.
    let streamSession: URLSession

    static let decoder = JSONDecoder()

    init(baseURL: String, token: String?) {
        self.baseURL = APIClient.normalize(baseURL)
        self.token = token
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.waitsForConnectivity = false
        // The token must not follow a redirect to another origin.
        session = URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
        let stream = URLSessionConfiguration.default
        stream.timeoutIntervalForRequest = .infinity
        stream.timeoutIntervalForResource = .infinity
        streamSession = URLSession(configuration: stream, delegate: SameOriginRedirects(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
        streamSession.finishTasksAndInvalidate()
    }

    /// Turns "192.168.1.5:8080" or "http://host:8080/" into a base URL ending in "/".
    static func normalize(_ raw: String) -> URL {
        var s = raw.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return URL(string: "http://localhost/")! }
        if !s.contains("://") { s = "http://" + s }
        return URL(string: s + "/") ?? URL(string: "http://localhost/")!
    }

    func url(_ path: String, _ query: [String: String] = [:]) -> URL {
        var c = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url!
    }

    func artifactURL(_ id: String) -> URL { url("artifacts/\(id)") }

    /// mobd's VNC relay: ws://host:port/vnc (wss for https).
    var vncURL: URL {
        var c = URLComponents(url: url("vnc"), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return c.url!
    }

    /// The /vnc WebSocket handshake; native clients authorize with the header, not a ticket.
    var vncRequest: URLRequest {
        var req = request(vncURL)
        req.setValue("binary", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return req
    }

    /// Every request to mobd starts here, so each one carries the token.
    func request(_ url: URL, method: String = "GET") -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if let token, !token.isEmpty { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    // MARK: - Requests

    private func check(_ data: Data, _ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(message: message ?? "HTTP \(http.statusCode)", status: http.statusCode)
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        var req = request(url(path, query), method: method)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: req)
        try check(data, response)
        return data
    }

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try APIClient.decoder.decode(T.self, from: await send("GET", path, query: query))
    }

    func health() async throws -> Health { try await get("health") }

    struct StreamAnswer: Decodable {
        let session: String
        let answer: String?
        let width: Int
        let height: Int
    }

    /// Opens a live desktop session (POST /stream); the answer has `session`, `width`, `height` and
    /// optionally `answer` (the remote SDP when mobd negotiated WebRTC; nil means WebSocket only).
    func openStream(offer: String, maxWidth: Int, maxHeight: Int, quality: String) async throws -> StreamAnswer {
        let data = try await send("POST", "stream", body: ["offer": offer, "maxWidth": maxWidth, "maxHeight": maxHeight, "quality": quality])
        return try APIClient.decoder.decode(StreamAnswer.self, from: data)
    }

    /// Closes a stream session (DELETE /stream/:id), fire and forget.
    func closeStream(_ id: String) {
        Task {
            do { _ = try await send("DELETE", "stream/\(id)") }
            catch {
                Task { @MainActor in Log.error("closeStream: \(readable(error))") }
            }
        }
    }

    /// archived: "false" (default), "true" or "all".
    func sessions(archived: String = "false") async throws -> [Session] {
        (try await get("sessions", query: ["archived": archived]) as SessionsResponse).sessions ?? []
    }

    func session(_ id: String) async throws -> SessionDetail { try await get("sessions/\(id)") }

    func patchSession(_ id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let pinned { body["pinned"] = pinned }
        if let archived { body["archived"] = archived }
        _ = try await send("PATCH", "sessions/\(id)", body: body)
    }

    func deleteSession(_ id: String) async throws { _ = try await send("DELETE", "sessions/\(id)") }

    func queue() async throws -> QueueState { try await get("queue") }

    func tasks(limit: Int = 100) async throws -> [AgentTask] {
        (try await get("tasks", query: ["limit": String(limit)]) as TasksResponse).tasks ?? []
    }

    func createTask(prompt: String, sessionId: String?, runner: String?, model: String?, effort: String?, attachments: [String]) async throws -> AgentTask {
        var body: [String: Any] = ["prompt": prompt]
        if let sessionId { body["sessionId"] = sessionId }
        if let runner { body["runner"] = runner }
        if let model { body["model"] = model }
        if let effort { body["effort"] = effort }
        if !attachments.isEmpty { body["attachments"] = attachments }
        return try APIClient.decoder.decode(AgentTask.self, from: await send("POST", "tasks", body: body))
    }

    func cancel(_ taskId: String) async throws { _ = try await send("POST", "tasks/\(taskId)/cancel") }

    func steer(_ taskId: String, prompt: String) async throws { _ = try await send("POST", "tasks/\(taskId)/steer", body: ["prompt": prompt]) }

    func answer(_ q: Question, answer: String?, approved: Bool?) async throws {
        try await self.answer(task: q.taskId, question: q.id, answer: answer, approved: approved)
    }

    func answer(task: String, question: String, answer: String?, approved: Bool?) async throws {
        var body: [String: Any] = [:]
        if let answer, !answer.isEmpty { body["answer"] = answer }
        if let approved { body["approved"] = approved }
        _ = try await send("POST", "tasks/\(task)/questions/\(question)/answer", body: body)
    }

    /// A desktop snapshot from GET /screen.
    func screen(maxWidth: Int) async throws -> UIImage {
        let data = try await send("GET", "screen", query: ["maxWidth": String(maxWidth), "quality": "70"])
        guard let image = UIImage(data: data) else { throw APIError(message: "Not an image", status: nil) }
        return image
    }

    func image(_ url: URL) async throws -> UIImage {
        let (data, response) = try await session.data(for: request(url))
        try check(data, response)
        guard let image = UIImage(data: data) else { throw APIError(message: "Not an image", status: nil) }
        return image
    }

    /// Uploads an image to POST /uploads as JPEG (photos may be HEIC; mobd accepts PNG/JPEG/GIF/WebP),
    /// scaled to at most 2560 px.
    func upload(_ image: UIImage, name: String) async throws -> Upload {
        let maxSide: CGFloat = 2560
        var img = image
        let longest = max(image.size.width, image.size.height) * image.scale
        if longest > maxSide {
            let s = maxSide / longest
            let size = CGSize(width: image.size.width * image.scale * s, height: image.size.height * image.scale * s)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            img = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        }
        guard let jpeg = img.jpegData(compressionQuality: 0.85) else { throw APIError(message: "Cannot encode \(name)", status: nil) }
        let boundary = "mob-\(UUID().uuidString)"
        var body = Data()
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name).jpg\"\r\nContent-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
        body.append(jpeg)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        var req = request(url("uploads"), method: "POST")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: req, from: body)
        try check(data, response)
        return try APIClient.decoder.decode(Upload.self, from: data)
    }
}
