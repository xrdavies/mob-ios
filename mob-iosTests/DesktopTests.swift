import XCTest
@testable import mob_ios

final class DesktopTests: XCTestCase {
    func testHealthSessionDesktops() {
        let h = Health(ok: true, features: ["sessionDesktops"], runners: nil, runner: nil, checks: nil)
        XCTAssertTrue(h.sessionDesktops)
        let old = Health(ok: true, features: ["stream"], runners: nil, runner: nil, checks: nil)
        XCTAssertFalse(old.sessionDesktops)
    }

    func testQueueReasonText() {
        XCTAssertEqual(queueReasonText("slots"), "Waiting for a free slot")
        XCTAssertEqual(queueReasonText("desktops"), "Waiting: the desktop limit is reached")
        XCTAssertEqual(queueReasonText("memory"), "Waiting: the office computer is low on memory")
        XCTAssertEqual(queueReasonText("disk"), "Waiting: the office computer is low on disk space")
        XCTAssertEqual(queueReasonText("desktopStarting"), "Starting the desktop")
        XCTAssertNil(queueReasonText("unknown"))
        XCTAssertNil(queueReasonText(nil))
    }

    func testQueuedLabel() {
        var t = AgentTask(id: "t", sessionId: "s", status: "queued", queuePosition: 2, queueReason: "memory")
        XCTAssertEqual(queuedLabel(t), "Queued #2 · Waiting: the office computer is low on memory")
        t.queuePosition = nil
        XCTAssertEqual(queuedLabel(t), "Queued · Waiting: the office computer is low on memory")
        t.queueReason = nil
        XCTAssertEqual(queuedLabel(t), "Queued · waits for the desktop")
    }

    func testResourceBanner() {
        let memLow = MemoryInfo(level: "low", availableBytes: 1 << 30, totalBytes: 8 << 30)
        let diskLow = DiskInfo(level: "low", freeBytes: 5 << 30, totalBytes: 100 << 30)
        let memCrit = MemoryInfo(level: "critical", availableBytes: 500 << 20, totalBytes: 8 << 30)
        let diskOk = DiskInfo(level: "ok", freeBytes: 50 << 30, totalBytes: 100 << 30)

        XCTAssertNil(ResourceBanner.make(memory: nil, disk: nil))
        XCTAssertNil(ResourceBanner.make(memory: MemoryInfo(level: "ok"), disk: diskOk))

        let b1 = ResourceBanner.make(memory: memLow, disk: nil)
        XCTAssertEqual(b1?.level, "low")
        XCTAssertTrue(b1?.text.contains("low on memory") == true)
        XCTAssertFalse(b1?.text.contains("New conversations wait") == true)

        let b2 = ResourceBanner.make(memory: nil, disk: diskLow)
        XCTAssertEqual(b2?.level, "low")
        XCTAssertTrue(b2?.text.contains("low on disk space") == true)

        let b3 = ResourceBanner.make(memory: memLow, disk: diskLow)
        XCTAssertEqual(b3?.level, "low")
        XCTAssertTrue(b3?.text.contains("low on memory and low on disk space") == true)

        let b4 = ResourceBanner.make(memory: memCrit, disk: diskOk)
        XCTAssertEqual(b4?.level, "critical")
        XCTAssertTrue(b4?.text.contains("New conversations wait until memory is freed.") == true)

        let b5 = ResourceBanner.make(memory: MemoryInfo(level: "ok"), disk: DiskInfo(level: "critical"))
        XCTAssertEqual(b5?.level, "critical")
        XCTAssertTrue(b5?.text.contains("until disk space is freed.") == true)

        XCTAssertNotEqual(b1?.dismissKey, b4?.dismissKey)
    }

    func testDesktopEventParsing() {
        let info = DesktopInfo(sessionId: "s1", state: "running", memoryBytes: 1 << 30, diskBytes: 2 << 30)
        let json = String(data: try! JSONEncoder().encode(info), encoding: .utf8)!
        let parsed = DesktopEvent.parse(type: "desktop", data: json)
        XCTAssertEqual(parsed, .desktop(info))

        let mem = MemoryInfo(level: "low", availableBytes: 1 << 30, totalBytes: 8 << 30)
        let memJson = String(data: try! JSONEncoder().encode(mem), encoding: .utf8)!
        XCTAssertEqual(DesktopEvent.parse(type: "memory", data: memJson), .memory(mem))

        XCTAssertNil(DesktopEvent.parse(type: "unknown", data: "{}"))
        XCTAssertNil(DesktopEvent.parse(type: "desktop", data: "not json"))
    }

    @MainActor
    func testDesktopMark() async {
        let store = DesktopStore()
        store.setEnabled(true)
        XCTAssertNil(store.mark("s1"))

        let running = DesktopInfo(sessionId: "s1", state: "running", memoryBytes: 100)
        store.apply(.desktop(running))
        XCTAssertEqual(store.mark("s1"), .running)

        let asleep = DesktopInfo(sessionId: "s2", state: "asleep", memoryBytes: 50)
        store.apply(.desktop(asleep))
        XCTAssertEqual(store.mark("s2"), .asleep)

        let closed = DesktopInfo(sessionId: "s1", state: "closed", memoryBytes: 0)
        store.apply(.desktop(closed))
        XCTAssertNil(store.mark("s1"))

        store.setEnabled(false)
        XCTAssertNil(store.mark("s2"))
    }

    func testStreamBodySessionId() {
        let body = APIClient.streamBody(offer: "sdp", maxWidth: 1920, maxHeight: 1080, quality: "auto", sessionId: "s1")
        XCTAssertEqual(body["sessionId"] as? String, "s1")
        XCTAssertEqual(body["offer"] as? String, "sdp")

        let noSession = APIClient.streamBody(offer: "sdp", maxWidth: 1920, maxHeight: 1080, quality: "auto", sessionId: nil)
        XCTAssertNil(noSession["sessionId"])
    }

    func testStreamErrorText() {
        let noDesktop = APIError(message: "msg", status: 409, code: "no_desktop")
        XCTAssertEqual(streamErrorText(noDesktop), noDesktopText)

        let notFound = APIError(message: "not found", status: 404, code: "session_not_found")
        XCTAssertEqual(streamErrorText(notFound), "not found")

        let generic = APIError(message: "generic", status: 500, code: nil)
        XCTAssertNil(streamErrorText(generic))
    }

    func testSeedErrorText() {
        let browser = APIError(message: "msg", status: 409, code: "browser_running")
        XCTAssertEqual(seedErrorText(browser), "Close the browser in this conversation first")

        let generic = APIError(message: "fail", status: 500, code: nil)
        XCTAssertEqual(seedErrorText(generic), "fail")
    }

    func testScreenURLSessionId() {
        let client = APIClient(baseURL: "http://localhost:8080", token: "tok")
        let url1 = client.screenURL(maxWidth: 1920, sessionId: "s1")
        XCTAssertTrue(url1.absoluteString.contains("sessionId=s1"))
        XCTAssertTrue(url1.absoluteString.contains("maxWidth=1920"))

        let url2 = client.screenURL(maxWidth: 1920, sessionId: nil)
        XCTAssertFalse(url2.absoluteString.contains("sessionId"))
    }
}
