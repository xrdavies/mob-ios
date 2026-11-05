import XCTest
@testable import mob_ios

/// The live view's log names the offer's candidates (mobd docs/live-view-cellular-investigation.md).
final class StreamDiagnosticsTests: XCTestCase {
    func testCandidateSummaryNamesTypeAddressProtocolAndNetworkCost() {
        let sdp = [
            "v=0",
            "a=candidate:1 1 UDP 2122260223 100.94.60.46 54321 typ host generation 0 network-id 3 network-cost 50",
            "a=candidate:2 1 udp 2122194687 10.20.30.40 54322 typ host generation 0 network-id 1 network-cost 900",
            "a=candidate:3 1 tcp 1518280447 100.94.60.46 9 typ host tcptype active",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=candidate:1 1 UDP 2122260223 100.94.60.46 54321 typ host generation 0 network-id 3 network-cost 50",
        ].joined(separator: "\r\n")
        XCTAssertEqual(StreamSession.candidateSummary(sdp),
                       "candidates: host 100.94.60.46 udp cost 50, host 10.20.30.40 udp cost 900, host 100.94.60.46 tcp")
        XCTAssertEqual(StreamSession.candidateSummary("v=0\r\n"), "no candidates")
    }
}
