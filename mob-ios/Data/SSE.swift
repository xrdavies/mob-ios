import Foundation

struct SSEEvent: Equatable {
    var id: String?
    var type: String
    var data: String
}

/// Parses server-sent events line by line (the "event:", "id:" and "data:" fields mob uses).
struct SSEParser {
    private var id: String?
    private var type = ""
    private var data: [String] = []

    /// Feeds one line; returns an event when a blank line ends one.
    mutating func line(_ line: String) -> SSEEvent? {
        if line.isEmpty {
            defer { type = ""; data = [] }
            guard !data.isEmpty || !type.isEmpty else { return nil }
            return SSEEvent(id: id, type: type.isEmpty ? "message" : type, data: data.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count > 1 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        switch field {
        case "event": type = value
        case "data": data.append(value)
        case "id": id = value
        default: break
        }
        return nil
    }
}

/// Pseudo event delivered once the stream is connected.
let sseOpen = "open"

extension APIClient {
    /// One event-stream connection. Ends when the server closes it; throws on network errors.
    func events(_ url: URL, lastEventId: String? = nil) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = request(url)
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    if let lastEventId { req.setValue(lastEventId, forHTTPHeaderField: "Last-Event-ID") }
                    let (bytes, response) = try await streamSession.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw APIError(message: "HTTP \(http.statusCode)", status: http.statusCode)
                    }
                    continuation.yield(SSEEvent(id: nil, type: sseOpen, data: ""))
                    var parser = SSEParser()
                    // `lines` drops empty lines, so read raw bytes to keep event boundaries.
                    var buffer = [UInt8]()
                    for try await byte in bytes {
                        if byte == UInt8(ascii: "\n") {
                            if buffer.last == UInt8(ascii: "\r") { buffer.removeLast() }
                            if let event = parser.line(String(decoding: buffer, as: UTF8.self)) { continuation.yield(event) }
                            buffer.removeAll(keepingCapacity: true)
                        } else {
                            buffer.append(byte)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
