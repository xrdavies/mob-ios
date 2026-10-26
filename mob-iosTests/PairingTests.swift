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
        let ws = c.streamSocketRequest(session: "S1")
        XCTAssertEqual(ws.url?.absoluteString, "ws://10.0.0.2:8080/stream/ws?session=S1")
        XCTAssertEqual(ws.value(forHTTPHeaderField: "Authorization"), "Bearer T0K")
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

    func testOldMachineJSONDecodesWithoutDesktopSignIn() throws {
        let old = #"[{"id":"m1","name":"Office","mobdUrl":"http://10.0.0.2:8080","vncUsername":"me","vncPassword":"pw"},{"id":"m2","name":"B","mobdUrl":"b"}]"#
        let list = try JSONDecoder().decode([Machine].self, from: Data(old.utf8))
        XCTAssertEqual(list.map(\.id), ["m1", "m2"])
        XCTAssertTrue(list.allSatisfy { $0.needsPairing && $0.serverId == nil })
        // VNC is gone: neither the sign-in user nor the password is written back.
        let saved = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
        XCTAssertFalse(saved.contains("vnc"))
        XCTAssertFalse(saved.contains("pw"))
    }

    func testLiveViewSettingsRoundTrip() throws {
        var m = Machine(id: "m", name: "Office", mobdUrl: "https://o.example")
        m.liveQuality = "low"
        m.liveWebSocket = true
        let back = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back.liveQuality, "low")
        XCTAssertEqual(back.liveWebSocket, true)
    }

    func testPairedMachineRoundTrip() throws {
        var m = Machine(id: "m", name: "Office", mobdUrl: "https://o.example")
        m.serverId = "S"
        m.addresses[0].clientId = "C"
        let back = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertFalse(back.needsPairing)
    }

    func testMachineSavedBeforeAddressesKeepsItsTokenAccount() throws {
        let old = #"[{"id":"m1","name":"Office","mobdUrl":"http://office.local:8080","serverId":"S","clientId":"C","needsPairing":false}]"#
        let m = try XCTUnwrap(JSONDecoder().decode([Machine].self, from: Data(old.utf8)).first)
        XCTAssertEqual(m.addresses.map(\.id), ["m1"])
        XCTAssertEqual(m.tokenAccount, "m1.token")
        XCTAssertEqual(m.mobdUrl, "http://office.local:8080")
        XCTAssertEqual(m.clientId, "C")
        XCTAssertFalse(m.needsPairing)
        let back = try JSONDecoder().decode(Machine.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
    }

    func testAddressKinds() {
        for lan in ["http://office-mac.local:8080", "http://192.168.1.20:8080", "http://10.0.0.2", "http://172.20.1.1", "http://[fd00::1]:8080"] {
            XCTAssertEqual(AddressKind.of(lan), .lan, lan)
        }
        for remote in ["https://office.tail49e461.ts.net", "https://mob.example.com", "http://100.101.1.2:8080", "http://172.32.0.1"] {
            XCTAssertEqual(AddressKind.of(remote), .remote, remote)
        }
    }

    func testPairingAddsASecondAddressToTheSameOffice() {
        var m = Machine(id: "m", name: "Office", mobdUrl: "http://office.local:8080")
        m.serverId = "S"
        let (two, n, dropped) = m.pairing(origin: "https://office.tail.ts.net", serverId: "S", clientId: "C2")
        XCTAssertEqual(n, 1)
        XCTAssertTrue(dropped.isEmpty)
        XCTAssertEqual(two.addresses.map(\.url), ["http://office.local:8080", "https://office.tail.ts.net"])
        XCTAssertEqual(two.addresses[0].tokenAccount, "m.token", "the first address keeps its token")
        XCTAssertNotEqual(two.addresses[1].tokenAccount, "m.token", "each address has its own token")
        XCTAssertEqual(two.mobdUrl, "https://office.tail.ts.net", "the new address is used")
        XCTAssertEqual(two.addresses.map { two.label($0) }, ["LAN", "Remote"])

        // The same address again is paired again, not added.
        let (again, i, _) = two.pairing(origin: "https://office.tail.ts.net", serverId: "S", clientId: "C3")
        XCTAssertEqual(i, 1)
        XCTAssertEqual(again.addresses.count, 2)
        XCTAssertEqual(again.clientId, "C3")

        // Another office replaces the addresses (the user confirmed it) and drops their tokens.
        let (other, _, gone) = two.pairing(origin: "http://10.0.0.9:8080", serverId: "T", clientId: "D")
        XCTAssertEqual(other.addresses.map(\.url), ["http://10.0.0.9:8080"])
        XCTAssertEqual(other.addresses[0].id, "m")
        XCTAssertEqual(Set(gone), Set(two.addresses.map(\.tokenAccount)))
    }

    func testRouteLabelsAndChoice() {
        var m = Machine(id: "m", name: "Office", mobdUrl: "https://a.ts.net")
        m.addresses.append(MachineAddress(id: "b", url: "https://b.example.com"))
        XCTAssertEqual(m.addresses.map { m.label($0) }, ["Remote", "Remote 2"])
        m.addresses[1].label = "Cloudflare"
        XCTAssertEqual(m.label(m.addresses[1]), "Cloudflare")
        XCTAssertEqual(m.mobdUrl, "https://a.ts.net", "the first address without a choice")
        m.route = "b"
        XCTAssertEqual(m.mobdUrl, "https://b.example.com")
        m.needsPairing = true
        XCTAssertTrue(m.addresses[1].needsPairing)
        XCTAssertFalse(m.addresses[0].needsPairing, "only the refused address needs pairing")
        m.route = "gone"
        XCTAssertEqual(m.mobdUrl, "https://a.ts.net")
    }
}
