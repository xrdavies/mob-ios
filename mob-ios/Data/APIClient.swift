import Foundation
import UIKit

/// A failure with a message the user can read (mobd answers errors as {"error": "...", "code": "..."}).
struct APIError: LocalizedError {
    let message: String
    let status: Int?
    /// mobd's machine-readable reason (no_desktop, browser_running…), when it sends one.
    var code: String? = nil
    var errorDescription: String? { message }
    /// mobd no longer accepts this device's token.
    var isUnauthorized: Bool { status == 401 }
}

extension Error {
    var isUnauthorized: Bool { (self as? APIError)?.isUnauthorized == true }

    /// mobd could not be reached at all (no network, the office computer asleep or off).
    var isUnreachable: Bool {
        guard let e = self as? URLError else { return false }
        return [.notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
                .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff].contains(e.code)
    }
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

    init(baseURL: String, token: String?, configuration: URLSessionConfiguration = .default) {
        self.baseURL = APIClient.normalize(baseURL)
        self.token = token
        let config = configuration
        // Remote routes (Tailscale Funnel's relays) can take seconds per request.
        config.timeoutIntervalForRequest = 20
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
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = body?["error"] as? String ?? APIClient.proxyMessage(http.statusCode) ?? "HTTP \(http.statusCode)"
            throw APIError(message: message, status: http.statusCode, code: body?["code"] as? String)
        }
    }

    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil) async throws -> Data {
        var req = request(url(path, query), method: method)
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) }
        catch where APIClient.shouldRetry(error, method: method) { (data, response) = try await session.data(for: req) }
        try check(data, response)
        return data
    }

    /// A gateway error without mobd's JSON body comes from the proxy in front of it (Tailscale
    /// Serve or Funnel): the office computer answered, mobd did not.
    static func proxyMessage(_ status: Int) -> String? {
        switch status {
        case 502, 503: return "The office computer answered, but mobd is not running there. Start it with mobd start."
        case 504: return "mobd did not answer in time"
        default: return nil
        }
    }

    /// A slow or dropped connection gets one more try, for reads only: a repeated POST could
    /// send the same message or answer twice.
    static func shouldRetry(_ error: Error, method: String) -> Bool {
        guard method == "GET", let e = error as? URLError else { return false }
        return e.code == .timedOut || e.code == .networkConnectionLost
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
        /// The answer to `audio`: "ready", or "unavailable" with a reason for the user.
        var audio: StreamAudio? = nil
    }

    struct StreamAudio: Decodable {
        let status: String
        var reason: String? = nil
    }

    /// Opens a live desktop session (POST /stream); the answer has `session`, `width`, `height` and
    /// optionally `answer` (the remote SDP when mobd negotiated WebRTC; nil means WebSocket only).
    func openStream(offer: String, maxWidth: Int, maxHeight: Int, quality: String, sessionId: String? = nil, audio: Bool = false) async throws -> StreamAnswer {
        let body = APIClient.streamBody(offer: offer, maxWidth: maxWidth, maxHeight: maxHeight, quality: quality, sessionId: sessionId, audio: audio)
        return try APIClient.decoder.decode(StreamAnswer.self, from: await send("POST", "stream", body: body))
    }

    /// The POST /stream body; `sessionId` picks the conversation's desktop (mobd with `sessionDesktops`).
    static func streamBody(offer: String, maxWidth: Int, maxHeight: Int, quality: String, sessionId: String?, audio: Bool = false) -> [String: Any] {
        var body: [String: Any] = ["offer": offer, "maxWidth": maxWidth, "maxHeight": maxHeight, "quality": quality]
        if let sessionId { body["sessionId"] = sessionId }
        if audio { body["audio"] = true }
        return body
    }

    /// A Mob relay's STUN and TURN servers (GET /stream/ice, mobd with `streamIce`), with TURN
    /// credentials minted for this device.
    struct IceServer: Decodable, Equatable {
        let urls: [String]
        var username: String? = nil
        var credential: String? = nil
    }

    func streamIce() async throws -> [IceServer] {
        struct Answer: Decodable { let iceServers: [IceServer]? }
        return (try await get("stream/ice") as Answer).iceServers ?? []
    }

    /// Closes a stream session (DELETE /stream/:id), fire and forget.
    /// GET /stream/ws for an open session, with the device token in the header (native clients need
    /// no ticket).
    func streamSocketRequest(session: String) -> URLRequest {
        var c = URLComponents(url: url("stream/ws", ["session": session]), resolvingAgainstBaseURL: false)!
        c.scheme = c.scheme == "https" ? "wss" : "ws"
        return request(c.url!)
    }

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

    /// With `since`, mobd may answer only the turns changed after that revision (see ChatDetail.merged).
    func session(_ id: String, since: Int64? = nil) async throws -> SessionDetail {
        try await get("sessions/\(id)", query: since.map { ["since": String($0)] } ?? [:])
    }

    /// A page of whole turns (`limit`, `before`) or the changes `since` a revision (mobd with "sessionHistory").
    func history(_ id: String, _ query: [String: String]) async throws -> SessionDetail {
        try await get("sessions/\(id)/history", query: query)
    }

    /// model / effort set the conversation's settings; "" returns to the machine default.
    @discardableResult
    func patchSession(_ id: String, title: String? = nil, pinned: Bool? = nil, archived: Bool? = nil,
                      model: String? = nil, effort: String? = nil) async throws -> Session {
        var body: [String: Any] = [:]
        if let title { body["title"] = title }
        if let pinned { body["pinned"] = pinned }
        if let archived { body["archived"] = archived }
        if let model { body["model"] = model }
        if let effort { body["effort"] = effort }
        return try APIClient.decoder.decode(Session.self, from: await send("PATCH", "sessions/\(id)", body: body))
    }

    func settings() async throws -> MachineSettingsInfo { try await get("settings") }

    /// Replaces the machine settings; APIError code "settings_changed" when another device saved first.
    func saveSettings(_ s: MachineSettings) async throws -> MachineSettingsInfo {
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any] ?? [:]
        return try APIClient.decoder.decode(MachineSettingsInfo.self, from: await send("PUT", "settings", body: body))
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

    /// GET /screen at `maxWidth`; `sessionId` picks the conversation's desktop (mobd with `sessionDesktops`).
    func screenURL(maxWidth: Int, sessionId: String?) -> URL {
        var query = ["maxWidth": String(maxWidth), "quality": "65"]
        if let sessionId { query["sessionId"] = sessionId }
        return url("screen", query)
    }

    /// A desktop snapshot from GET /screen; `image` is nil when the screen is unchanged since `etag`
    /// (304), so polling an idle desktop downloads nothing. `asleep`: the last frame of a sleeping
    /// desktop, which a snapshot does not wake.
    func screen(maxWidth: Int, etag: String?, sessionId: String? = nil) async throws -> (image: UIImage?, etag: String?, asleep: Bool) {
        var req = request(screenURL(maxWidth: maxWidth, sessionId: sessionId))
        req.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        let (data, response) = try await session.data(for: req)
        let http = response as? HTTPURLResponse
        let asleep = http?.value(forHTTPHeaderField: "X-Mob-Desktop-State") == "asleep"
        if http?.statusCode == 304 { return (nil, etag, asleep) }
        try check(data, response)
        guard let image = UIImage(data: data) else { throw APIError(message: "Not an image", status: nil) }
        return (image, http?.value(forHTTPHeaderField: "ETag"), asleep)
    }

    // MARK: Conversation desktops (Linux mobd)

    func desktops() async throws -> DesktopsResponse { try await get("desktops") }

    /// Stops the conversation's running turn, then closes its desktop.
    func closeDesktop(_ sessionId: String) async throws { _ = try await send("DELETE", "desktops/\(sessionId)") }

    /// New conversations start with this conversation's browser profiles.
    func seedDesktop(_ sessionId: String) async throws { _ = try await send("POST", "desktops/\(sessionId)/seed") }

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
