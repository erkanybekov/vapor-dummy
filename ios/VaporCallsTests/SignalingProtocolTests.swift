import Foundation
import Testing
@testable import VaporCalls

/// The app must read exactly what the Vapor server sends and write what it
/// expects. The JSON samples follow ServerMessage.encode(to:) on the server.
@Suite("Signaling protocol")
struct SignalingProtocolTests {
    private func decode(_ json: String) throws -> ServerMessage {
        try JSONDecoder().decode(ServerMessage.self, from: Data(json.utf8))
    }

    private func encode(_ message: ClientMessage) throws -> [String: Any] {
        let data = try JSONEncoder().encode(message)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func decodesIncomingCall() throws {
        let callId = UUID()
        let userId = UUID()
        let message = try decode("""
        {"type":"call.incoming","callId":"\(callId)","video":true,
         "caller":{"userId":"\(userId)","username":"erlan","deviceId":"mac-1","deviceName":"Mac · Chrome"}}
        """)
        #expect(message == .incoming(callId: callId,
                                     caller: CallPeer(userId: userId, username: "erlan", deviceId: "mac-1", deviceName: "Mac · Chrome"),
                                     video: true))
    }

    @Test func decodesHelloWithIceServers() throws {
        let message = try decode("""
        {"type":"hello","userId":"\(UUID())","deviceId":"d","iceServers":[
          {"urls":["stun:stun.l.google.com:19302"]},
          {"urls":["turn:turn.example.com:3478"],"username":"1700000000:u","credential":"c2VjcmV0"}]}
        """)
        guard case let .hello(_, _, servers) = message else {
            Issue.record("Expected hello, got \(message)")
            return
        }
        #expect(servers.count == 2)
        #expect(servers[0].username == nil)
        #expect(servers[1].credential == "c2VjcmV0")
    }

    @Test func decodesEndReasonsAndCandidates() throws {
        let callId = UUID()
        #expect(try decode(#"{"type":"call.ended","callId":"\#(callId)","reason":"answered_elsewhere"}"#)
            == .ended(callId: callId, reason: .answeredElsewhere))

        let signal = try decode("""
        {"type":"call.signal","callId":"\(callId)","from":"mac-1",
         "signal":{"kind":"candidate","candidate":{"candidate":"candidate:1 1 udp 2122260223 192.168.0.10 50000 typ host","sdpMid":"0","sdpMLineIndex":0}}}
        """)
        guard case let .signal(_, from, payload) = signal else {
            Issue.record("Expected call.signal")
            return
        }
        #expect(from == "mac-1")
        #expect(payload.candidate?.sdpMLineIndex == 0)
    }

    @Test func toleratesUnknownMessageTypes() throws {
        #expect(try decode(#"{"type":"call.someday","whatever":1}"#) == .unknown(type: "call.someday"))
    }

    @Test func encodesClientMessagesInServerShape() throws {
        let invite = try encode(.invite(calleeEmail: "me@example.com", calleeId: nil, video: true))
        #expect(invite["type"] as? String == "call.invite")
        #expect(invite["calleeEmail"] as? String == "me@example.com")
        #expect(invite["calleeId"] == nil)
        #expect(invite["video"] as? Bool == true)

        let callId = UUID()
        let offer = try encode(.signal(callId: callId, signal: SignalPayload(kind: .offer, sdp: "v=0")))
        #expect(offer["type"] as? String == "call.signal")
        #expect(offer["callId"] as? String == callId.uuidString)
        let signal = try #require(offer["signal"] as? [String: Any])
        #expect(signal["kind"] as? String == "offer")
        #expect(signal["sdp"] as? String == "v=0")
    }

    @Test func keepsQueryStringsInAPIPaths() {
        let url = APIClient.url(for: "calls/history?limit=30")
        #expect(url.path().hasSuffix("/api/v1/calls/history"))
        #expect(url.query() == "limit=30")
    }

    @Test func readsJWTExpiry() {
        let payload = Data(#"{"exp":1800000000,"sub":"x"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        let token = "header.\(payload).signature"
        #expect(APIClient.expiry(of: token) == Date(timeIntervalSince1970: 1_800_000_000))
        #expect(APIClient.expiry(of: "not-a-jwt") == nil)
    }
}
