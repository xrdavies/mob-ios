import XCTest
@testable import mob_ios

final class PairingTests: XCTestCase {
    private func parse(_ s: String) -> PairLink? { try? PairLink.parse(s) }

    private func message(_ s: String) -> String? {
        do { _ = try PairLink.parse(s); return nil } catch { return (error as? PairError)?.message }
    }

    func testParseValidLinks() throws {
        XCTAssertEqual(try PairLink.parse("  https://office.example.com/pair#invite=I&serverId=S&v=1\n"),
                       PairLink(origin: "https://office.example.com", invite: "I", serverId: "S"))
        let lan = try PairLink.parse("http://192.168.1.20:8080/pair#v=1&serverId=S&invite=I")
        XCTAssertEqual(lan.origin, "http://192.168.1.20:8080")
        XCTAssertTrue(lan.isInsecure)
        XCTAssertFalse(try PairLink.parse("HTTPS://Office.Example.com:8443/pair#serverId=S&v=1&invite=I").isInsecure)
        XCTAssertEqual(parse("HTTPS://Office.Example.com:8443/pair#serverId=S&v=1&invite=I")?.origin, "https://office.example.com:8443")
        XCTAssertEqual(parse("http://[fd7a:115c::1]:8080/pair#v=1&invite=I&serverId=S")?.origin, "http://[fd7a:115c::1]:8080")
        XCTAssertEqual(parse("http://h/pair#v=1&invite=a%2Bb&serverId=S")?.invite, "a+b")
    }

    func testParseRejects() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("not a link"))
        XCTAssertNotNil(message("http://h/pair#invite=I&serverId=S"), "missing v")
        XCTAssertNil(parse("http://h/pair#v=2&invite=I&serverId=S"))
        XCTAssertNil(parse("http://h/pair#v=1&serverId=S"), "missing invite")
        XCTAssertNil(parse("http://h/pair#v=1&invite=I"), "missing serverId")
        XCTAssertNil(parse("http://h/pair#v=1&invite=&serverId=S"))
        XCTAssertNil(parse("http://h/pair"), "no fragment")
        XCTAssertNil(parse("http://h/pairing#v=1&invite=I&serverId=S"))
        XCTAssertNil(parse("http://h/pair/#v=1&invite=I&serverId=S"))
        XCTAssertNil(parse("http://h/x/pair#v=1&invite=I&serverId=S"))
        XCTAssertNil(parse("http://h/pair?x=1#v=1&invite=I&serverId=S"), "query")
        XCTAssertNil(parse("http://h/pair?#v=1&invite=I&serverId=S"), "empty query")
        XCTAssertNil(parse("http://u:p@h/pair#v=1&invite=I&serverId=S"), "userinfo")
        XCTAssertNil(parse("http://u@h/pair#v=1&invite=I&serverId=S"), "user")
        XCTAssertNil(parse("ftp://h/pair#v=1&invite=I&serverId=S"))
        XCTAssertNil(parse("mob://h/pair#v=1&invite=I&serverId=S"))
        XCTAssertNil(parse("http://h/pair#v=1&invite=I&invite=J&serverId=S"), "repeated key")
        XCTAssertEqual(message("http://h/pair#invite=I&serverId=S"), "The link is incomplete: v is missing")
    }

    func testValidName() {
        XCTAssertEqual(PairLink.validName("  My iPhone "), "My iPhone")
        XCTAssertNil(PairLink.validName("   "))
        XCTAssertNil(PairLink.validName("a\u{7}b"))
        XCTAssertNil(PairLink.validName(String(repeating: "é", count: 65)), "130 bytes")
        XCTAssertNotNil(PairLink.validName(String(repeating: "a", count: 128)))
    }

    func testSameOrigin() {
        let u = { (s: String) in URL(string: s)! }
        XCTAssertTrue(sameOrigin(u("http://h/pair"), u("http://H:80/other")))
        XCTAssertTrue(sameOrigin(u("https://h/a"), u("https://h:443/b")))
        XCTAssertFalse(sameOrigin(u("http://h/a"), u("https://h/a")))
        XCTAssertFalse(sameOrigin(u("http://h:8080/a"), u("http://h:8081/a")))
        XCTAssertFalse(sameOrigin(u("http://h/a"), u("http://evil/a")))
    }

    func testAuthorizationOnRequests() {
        let c = APIClient(baseURL: "http://10.0.0.2:8080", token: "T0K")
        XCTAssertEqual(c.request(c.url("health")).value(forHTTPHeaderField: "Authorization"), "Bearer T0K")
        XCTAssertEqual(c.request(c.url("uploads"), method: "POST").httpMethod, "POST")
        let vnc = c.vncRequest
        XCTAssertEqual(vnc.url?.absoluteString, "ws://10.0.0.2:8080/vnc")
        XCTAssertEqual(vnc.value(forHTTPHeaderField: "Authorization"), "Bearer T0K")
        XCTAssertEqual(vnc.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "binary")
        let none = APIClient(baseURL: "http://10.0.0.2:8080", token: nil)
        XCTAssertNil(none.request(none.url("health")).value(forHTTPHeaderField: "Authorization"))
    }

    func testUnauthorizedIsReadable() {
        let e: Error = APIError(message: "unauthorized", status: 401)
        XCTAssertTrue(e.isUnauthorized)
        XCTAssertEqual(readable(e), "This device needs to be paired again")
        XCTAssertFalse(APIError(message: "x", status: 500).isUnauthorized)
    }

    func testKeychainRoundTrip() throws {
        let account = "test-\(UUID().uuidString).token"
        defer { Keychain.delete(account) }
        guard Keychain.set("secret", for: account) else { throw XCTSkip("Keychain not available in this test host") }
        XCTAssertEqual(Keychain.get(account), "secret")
        XCTAssertTrue(Keychain.set("other", for: account))
        XCTAssertEqual(Keychain.get(account), "other")
        XCTAssertTrue(Keychain.delete(account))
        XCTAssertNil(Keychain.get(account))
        XCTAssertTrue(Keychain.set("x", for: account))
        XCTAssertTrue(Keychain.set(nil, for: account))
        XCTAssertNil(Keychain.get(account))
    }

    func testOldMachineJSONDecodes() throws {
        let old = #"[{"id":"m1","name":"Office","mobdUrl":"http://10.0.0.2:8080","vncUsername":"me","vncPassword":"pw"},{"id":"m2","name":"B","mobdUrl":"b"}]"#
        let data = Data(old.utf8)
        let list = try JSONDecoder().decode([Machine].self, from: data)
        XCTAssertEqual(list.map(\.id), ["m1", "m2"])
        XCTAssertEqual(list[0].vncUsername, "me")
        XCTAssertEqual(list[1].vncUsername, "")
        XCTAssertTrue(list.allSatisfy { $0.needsPairing && $0.serverId == nil })
        XCTAssertEqual(Machine.legacyPasswords(data), ["m1": "pw"])
        // The password is not written back.
        let saved = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        XCTAssertFalse(saved.contains("vncPassword"))
        XCTAssertFalse(saved.contains("pw"))
    }

    func testPairedMachineRoundTrip() throws {
        var m = Machine(id: "m", name: "Office", mobdUrl: "https://o.example")
        m.serverId = "S"
        m.clientId = "C"
        let back = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertFalse(back.needsPairing)
        XCTAssertEqual(Machine.legacyPasswords(try JSONEncoder().encode([m])), [:])
    }
}
