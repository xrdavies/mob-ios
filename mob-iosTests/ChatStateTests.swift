import XCTest
@testable import mob_ios

@MainActor
final class ChatStateTests: XCTestCase {
    func testDraftsKeepTextAndUploadsWithTheirConversation() {
        let drafts = ChatDrafts()
        let a = drafts.draft(machine: "office", session: "A")
        a.text = "A draft"
        let image = DraftAttachment()
        a.attachments = [image]
        XCTAssertFalse(a.attachmentsReady)
        image.error = "Upload failed"
        XCTAssertFalse(a.attachmentsReady)
        image.error = nil
        image.uploadId = "image"
        XCTAssertTrue(a.attachmentsReady)
        XCTAssertTrue(drafts.draft(machine: "office", session: "A") === a)
        for other in [drafts.draft(machine: "office", session: "B"),
                      drafts.draft(machine: "other-office", session: "A"),
                      drafts.draft(machine: "office", session: nil)] {
            XCTAssertTrue(other.text.isEmpty)
            XCTAssertTrue(other.attachments.isEmpty)
        }
        a.beginSending()
        a.finishSending(false)
        XCTAssertFalse(a.sending)
        XCTAssertEqual(a.text, "A draft")
        XCTAssertTrue(a.attachments.first === image)
        a.beginSending()
        a.finishSending(true)
        XCTAssertTrue(a.text.isEmpty)
        XCTAssertTrue(a.attachments.isEmpty)
    }

    func testLateSendDoesNotReopenPreviousConversation() async throws {
        let (store, client, machine) = makeStore()
        defer { store.attach(nil, machine: ""); UserDefaults.standard.removeObject(forKey: "session.\(machine)") }
        store.open("A")
        let request = expectation(description: "send started")
        let done = expectation(description: "send completed")
        var pending: ChatHTTPStub?
        ChatHTTPStub.create = { pending = $0; request.fulfill() }
        store.send("hello") { XCTAssertTrue($0); done.fulfill() }
        await fulfillment(of: [request], timeout: 2)
        store.open("B")
        pending?.respond(#"{"id":"t","sessionId":"A","status":"queued"}"#)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(store.currentId, "B")
        XCTAssertFalse(store.sending)
        _ = client
    }

    func testOldMachineCompletionDoesNotChangeNewSend() async throws {
        let (store, client, machine) = makeStore()
        defer { store.attach(nil, machine: ""); UserDefaults.standard.removeObject(forKey: "session.\(machine)") }
        let first = expectation(description: "old send started")
        let second = expectation(description: "new send started")
        let oldDone = expectation(description: "old send ended")
        let newDone = expectation(description: "new send ended")
        var old: ChatHTTPStub?, new: ChatHTTPStub?
        ChatHTTPStub.create = { old = $0; first.fulfill() }
        store.send("old") { XCTAssertFalse($0); oldDone.fulfill() }
        await fulfillment(of: [first], timeout: 2)
        store.attach(client, machine: machine)
        XCTAssertNil(store.outbox)
        XCTAssertFalse(store.sending)
        ChatHTTPStub.create = { new = $0; second.fulfill() }
        store.send("new") { XCTAssertTrue($0); newDone.fulfill() }
        await fulfillment(of: [second], timeout: 2)
        old?.respond(#"{"error":"offline"}"#, status: 503)
        await fulfillment(of: [oldDone], timeout: 2)
        XCTAssertTrue(store.sending)
        XCTAssertEqual(store.outbox?.text, "new")
        XCTAssertNil(store.error)
        new?.respond(#"{"id":"t2","sessionId":"created","status":"queued"}"#)
        await fulfillment(of: [newDone], timeout: 2)
        XCTAssertEqual(store.currentId, "created")
    }

    func testLateNewChatDoesNotReplaceAnotherNewChat() async {
        let (store, _, machine) = makeStore()
        defer { store.attach(nil, machine: ""); UserDefaults.standard.removeObject(forKey: "session.\(machine)") }
        let started = expectation(description: "new chat request")
        let done = expectation(description: "new chat accepted")
        var pending: ChatHTTPStub?
        ChatHTTPStub.create = { pending = $0; started.fulfill() }
        store.send("first new chat") { XCTAssertTrue($0); done.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        store.open("B")
        store.open(nil)
        pending?.respond(#"{"id":"t","sessionId":"created","status":"queued"}"#)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.currentId)
        XCTAssertFalse(store.loading)
    }

    func testOldUnauthorizedSendDoesNotInvalidateTheNewMachine() async {
        let (store, client, machine) = makeStore()
        defer { store.attach(nil, machine: ""); UserDefaults.standard.removeObject(forKey: "session.\(machine)") }
        let started = expectation(description: "old request")
        let done = expectation(description: "old unauthorized response")
        var pending: ChatHTTPStub?
        ChatHTTPStub.create = { pending = $0; started.fulfill() }
        store.onUnauthorized = { _ in XCTFail("old response invalidated the current machine") }
        store.send("old") { XCTAssertFalse($0); done.fulfill() }
        await fulfillment(of: [started], timeout: 2)
        store.attach(client, machine: machine)
        pending?.respond(#"{"error":"unauthorized"}"#, status: 401)
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNil(store.error)
        XCTAssertNil(store.outbox)
    }

    func testFailedAnswerCompletesAndCanBeRetried() async {
        let (store, _, machine) = makeStore()
        defer { store.attach(nil, machine: ""); UserDefaults.standard.removeObject(forKey: "session.\(machine)") }
        let q = Question(id: "q", taskId: "t", kind: "approval", text: "Approve?", details: nil, options: nil,
                         allowText: nil, status: "pending", answer: nil, approved: nil, createdAt: nil)
        let failed = expectation(description: "failed answer released")
        ChatHTTPStub.answerStatus = 503
        store.answer(q, answer: nil, approved: true) { XCTAssertFalse($0); failed.fulfill() }
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNotNil(store.error)
        let retried = expectation(description: "retry released")
        ChatHTTPStub.answerStatus = 200
        store.error = nil
        store.answer(q, answer: nil, approved: true) { XCTAssertTrue($0); retried.fulfill() }
        await fulfillment(of: [retried], timeout: 2)
        XCTAssertNil(store.error)
    }

    private func makeStore() -> (ChatStore, APIClient, String) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChatHTTPStub.self]
        let client = APIClient(baseURL: "https://chat-tests.invalid", token: nil, configuration: config)
        let store = ChatStore()
        let machine = "test-\(UUID())"
        store.attach(client, machine: machine)
        return (store, client, machine)
    }
}

private final class ChatHTTPStub: URLProtocol {
    @MainActor static var create: ((ChatHTTPStub) -> Void)?
    @MainActor static var answerStatus = 200

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "chat-tests.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Task { @MainActor in
            let path = request.url!.path
            if request.httpMethod == "POST", path == "/tasks" { Self.create?(self) }
            else if path.hasSuffix("/answer") { respond(#"{"error":"answer failed"}"#, status: Self.answerStatus) }
            else if path == "/sessions" { respond(#"{"sessions":[]}"#) }
            else { respond("{\"session\":{\"id\":\"\(request.url!.lastPathComponent)\"},\"tasks\":[]}") }
        }
    }
    override func stopLoading() {}
    func respond(_ body: String, status: Int = 200) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
