import Foundation

/// A failure while reading a pairing link or pairing, with a message the user can read.
struct PairError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// A link printed by `mobd link`: <origin>/pair#v=1&serverId=S&invite=I.
struct PairLink: Equatable {
    /// scheme://host[:port], lower-cased; the address mob talks to afterwards.
    let origin: String
    let invite: String
    let serverId: String

    var isInsecure: Bool { origin.hasPrefix("http://") }

    static func parse(_ text: String) throws -> PairLink {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw PairError(message: "Paste the link printed by mobd link") }
        guard let c = URLComponents(string: s), let scheme = c.scheme?.lowercased() else {
            throw PairError(message: "This is not a link")
        }
        guard scheme == "http" || scheme == "https" else { throw PairError(message: "The link must start with http:// or https://") }
        guard var host = c.encodedHost?.lowercased(), !host.isEmpty else { throw PairError(message: "The link has no address") }
        guard c.user == nil, c.password == nil else { throw PairError(message: "The link must not contain a user name or password") }
        guard c.path == "/pair" else { throw PairError(message: "Not a pairing link: the path must be /pair") }
        guard c.query == nil else { throw PairError(message: "Not a pairing link: it must not have a query (?…)") }
        guard let fragment = c.fragment, !fragment.isEmpty else { throw PairError(message: "The link is incomplete: the part after # is missing") }

        var params: [String: String] = [:]
        for pair in fragment.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? "") : ""
            guard params[key] == nil else { throw PairError(message: "The link repeats \(key)") }
            params[key] = value
        }
        guard let v = params["v"] else { throw PairError(message: "The link is incomplete: v is missing") }
        guard v == "1" else { throw PairError(message: "This link needs a newer version of Mob") }
        guard let invite = params["invite"], !invite.isEmpty else { throw PairError(message: "The link is incomplete: invite is missing") }
        guard let serverId = params["serverId"], !serverId.isEmpty else { throw PairError(message: "The link is incomplete: serverId is missing") }

        if host.contains(":") && !host.hasPrefix("[") { host = "[\(host)]" }
        let origin = "\(scheme)://\(host)" + (c.port.map { ":\($0)" } ?? "")
        return PairLink(origin: origin, invite: invite, serverId: serverId)
    }

    /// mobd accepts 1–128 bytes after trimming, without control characters.
    static func validName(_ name: String) -> String? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, n.utf8.count <= 128, !n.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return n
    }
}

/// What POST /pair returns: the office's identity and this device's credential.
struct PairResult: Decodable, Equatable {
    let serverId: String
    let clientId: String
    let token: String
}

/// Follows redirects only within the original origin, so an invite or token never leaves it.
final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = task.originalRequest?.url, let to = request.url, sameOrigin(from, to) else { return completionHandler(nil) }
        completionHandler(request)
    }
}

func sameOrigin(_ a: URL, _ b: URL) -> Bool {
    func port(_ u: URL) -> Int? { u.port ?? (u.scheme?.lowercased() == "https" ? 443 : u.scheme?.lowercased() == "http" ? 80 : nil) }
    return a.scheme?.lowercased() == b.scheme?.lowercased() && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
}

/// Redeems the invite: POST <origin>/pair {"invite", "name"} → 201 {serverId, clientId, token}.
func pair(link: PairLink, name: String) async throws -> PairResult {
    guard let name = PairLink.validName(name) else {
        throw PairError(message: "Enter a device name of at most 128 bytes, without control characters")
    }
    guard let url = URL(string: link.origin + "/pair") else { throw PairError(message: "The link has an invalid address") }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONEncoder().encode(["invite": link.invite, "name": name])
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    let session = URLSession(configuration: config, delegate: SameOriginRedirects(), delegateQueue: nil)
    defer { session.finishTasksAndInvalidate() }

    let (data, response) = try await session.data(for: req)
    guard let http = response as? HTTPURLResponse else { throw PairError(message: "mobd sent no HTTP response") }
    switch http.statusCode {
    case 200..<300: break
    case 300..<400: throw PairError(message: "The address redirected elsewhere, so pairing stopped. Use the link exactly as mobd link printed it.")
    case 401: throw PairError(message: "This invitation is invalid, expired or already used. Run mobd link again on the office Mac.")
    case 400:
        let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
        throw PairError(message: "mobd rejected the request" + (detail.map { ": \($0)" } ?? ". Check the device name."))
    case 503: throw PairError(message: "The office Mac could not save the pairing (storage problem). Check mobd there and try again.")
    case 404:
        // mobd answers pairing_closed while no invitation is open (used, expired or closed).
        let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
        if code == "pairing_closed" {
            throw PairError(message: "This invitation is invalid, expired or already used. Run mobd link again on the office Mac.")
        }
        throw PairError(message: "This mobd does not support pairing. Update mobd on the office Mac.")
    default: throw PairError(message: "Pairing failed: HTTP \(http.statusCode)")
    }
    guard let result = try? JSONDecoder().decode(PairResult.self, from: data), !result.token.isEmpty, !result.clientId.isEmpty else {
        throw PairError(message: "mobd answered with an unexpected pairing response")
    }
    guard result.serverId == link.serverId else {
        throw PairError(message: "The office at this address is not the one in the link (server ID differs). Pairing stopped.")
    }
    return result
}
