@testable import hello
import Foundation
import Testing

// MARK: - Test Doubles

final class FakeConnection: SignalingConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [ServerMessage] = []
    private var isClosed = false

    func send(_ message: ServerMessage) {
        lock.withLock { sent.append(message) }
    }

    func close() {
        lock.withLock { isClosed = true }
    }

    var messages: [ServerMessage] { lock.withLock { sent } }
    var closed: Bool { lock.withLock { isClosed } }

    func clear() {
        lock.withLock { sent.removeAll() }
    }

    var incomingCallIds: [UUID] {
        messages.compactMap { if case let .callIncoming(callId, _, _) = $0 { callId } else { nil } }
    }

    var ringingCallId: UUID? {
        messages.compactMap { if case let .callRinging(callId, _, _) = $0 { callId } else { nil } }.last
    }

    var endReasons: [CallEndReason] {
        messages.compactMap { if case let .callEnded(_, reason) = $0 { reason } else { nil } }
    }

    var errorCodes: [SignalingErrorCode] {
        messages.compactMap { if case let .error(code, _, _) = $0 { code } else { nil } }
    }

    var signals: [SignalPayload] {
        messages.compactMap { if case let .callSignal(_, _, signal) = $0 { signal } else { nil } }
    }
}

final class RecordSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CallRecord] = []

    func append(_ record: CallRecord) {
        lock.withLock { stored.append(record) }
    }

    var records: [CallRecord] { lock.withLock { stored } }
}

/// One signed-in device with its socket.
struct TestDevice {
    let peer: CallPeer
    let connection = FakeConnection()

    init(user: UUID, username: String = "erlan", id: String, name: String? = nil) {
        peer = CallPeer(userId: user, username: username, deviceId: id, deviceName: name ?? id)
    }

    func connect(to hub: CallHub) async {
        await hub.connect(connection, peer: peer, iceServers: [])
    }

    func disconnect(from hub: CallHub) async {
        await hub.disconnect(connection, userId: peer.userId, deviceId: peer.deviceId)
    }

    func send(_ command: CallHub.Command, to hub: CallHub) async {
        await hub.handle(command, from: connection, userId: peer.userId, deviceId: peer.deviceId)
    }
}

private func eventually(timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Call Hub Tests

@Suite("Call Hub")
struct CallHubTests {
    let me = UUID()
    let friend = UUID()
    let sink = RecordSink()

    func makeHub(ringTimeout: Duration = .seconds(30), reconnectGrace: Duration = .seconds(15)) -> CallHub {
        let sink = self.sink
        return CallHub(
            configuration: .init(ringTimeout: ringTimeout, reconnectGrace: reconnectGrace),
            onRecord: { sink.append($0) }
        )
    }

    /// Mac calls my own account, iPhone answers. Returns the call id.
    func startSelfCall(_ hub: CallHub, mac: TestDevice, phone: TestDevice) async throws -> UUID {
        await mac.connect(to: hub)
        await phone.connect(to: hub)
        await mac.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)
        let callId = try #require(mac.connection.ringingCallId)
        await phone.send(.accept(callId: callId), to: hub)
        return callId
    }

    @Test("Calling yourself rings your other devices, not the calling one")
    func selfCallRingsOtherDevices() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        await mac.connect(to: hub)
        await phone.connect(to: hub)

        await mac.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)

        let callId = try #require(mac.connection.ringingCallId)
        #expect(phone.connection.incomingCallIds == [callId])
        #expect(mac.connection.incomingCallIds.isEmpty)
        #expect(mac.connection.messages.contains(.callRinging(callId: callId, callee: CallUser(id: me, username: "erlan"), devices: 1)))
    }

    @Test("Answering connects both devices with roles and relays SDP both ways")
    func acceptAndRelay() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        let callId = try await startSelfCall(hub, mac: mac, phone: phone)

        #expect(mac.connection.messages.contains(.callAccepted(callId: callId, peer: phone.peer, role: .caller, video: true)))
        #expect(phone.connection.messages.contains(.callAccepted(callId: callId, peer: mac.peer, role: .callee, video: true)))

        let offer = SignalPayload(kind: .offer, sdp: "v=0 offer")
        let answer = SignalPayload(kind: .answer, sdp: "v=0 answer")
        await mac.send(.signal(callId: callId, signal: offer), to: hub)
        await phone.send(.signal(callId: callId, signal: answer), to: hub)

        #expect(phone.connection.signals == [offer])
        #expect(mac.connection.signals == [answer])
    }

    @Test("When one device answers, the others stop ringing")
    func answeredElsewhere() async throws {
        let hub = makeHub()
        let caller = TestDevice(user: friend, username: "friend", id: "pixel")
        let phone = TestDevice(user: me, id: "iphone")
        let mac = TestDevice(user: me, id: "mac")
        for device in [caller, phone, mac] { await device.connect(to: hub) }

        await caller.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)
        let callId = try #require(caller.connection.ringingCallId)
        #expect(phone.connection.incomingCallIds == [callId])
        #expect(mac.connection.incomingCallIds == [callId])

        await phone.send(.accept(callId: callId), to: hub)

        #expect(mac.connection.endReasons == [.answeredElsewhere])
        await mac.send(.accept(callId: callId), to: hub)
        #expect(mac.connection.errorCodes == [.callNotFound])
    }

    @Test("Declining ends the call for the caller and every ringing device")
    func decline() async throws {
        let hub = makeHub()
        let caller = TestDevice(user: friend, username: "friend", id: "pixel")
        let phone = TestDevice(user: me, id: "iphone")
        let mac = TestDevice(user: me, id: "mac")
        for device in [caller, phone, mac] { await device.connect(to: hub) }

        await caller.send(.invite(callee: CallUser(id: me, username: "erlan"), video: false), to: hub)
        let callId = try #require(caller.connection.ringingCallId)
        await phone.send(.decline(callId: callId), to: hub)

        #expect(caller.connection.endReasons == [.declined])
        #expect(mac.connection.endReasons == [.declined])
        #expect(sink.records.last?.status == .declined)
    }

    @Test("Calling an account with no other online device is unavailable")
    func unavailable() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        await mac.connect(to: hub)

        await mac.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)

        #expect(mac.connection.endReasons == [.unavailable])
        #expect(sink.records.map(\.status) == [.unavailable])
    }

    @Test("Calling someone whose devices are all in calls is busy")
    func busy() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        _ = try await startSelfCall(hub, mac: mac, phone: phone)

        let caller = TestDevice(user: friend, username: "friend", id: "pixel")
        await caller.connect(to: hub)
        await caller.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)

        #expect(caller.connection.endReasons == [.busy])
    }

    @Test("A device already in a call cannot start another one")
    func alreadyInCall() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        _ = try await startSelfCall(hub, mac: mac, phone: phone)

        await mac.send(.invite(callee: CallUser(id: friend, username: "friend"), video: true), to: hub)

        #expect(mac.connection.errorCodes == [.alreadyInCall])
    }

    @Test("Unanswered calls time out as missed")
    func ringTimeout() async throws {
        let hub = makeHub(ringTimeout: .milliseconds(50))
        let caller = TestDevice(user: friend, username: "friend", id: "pixel")
        let phone = TestDevice(user: me, id: "iphone")
        await caller.connect(to: hub)
        await phone.connect(to: hub)

        await caller.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)

        #expect(await eventually { caller.connection.endReasons == [.timeout] })
        #expect(phone.connection.endReasons == [.timeout])
        #expect(sink.records.last?.status == .missed)
    }

    @Test("Caller hanging up before an answer cancels the call")
    func cancelBeforeAnswer() async throws {
        let hub = makeHub()
        let caller = TestDevice(user: friend, username: "friend", id: "pixel")
        let phone = TestDevice(user: me, id: "iphone")
        await caller.connect(to: hub)
        await phone.connect(to: hub)

        await caller.send(.invite(callee: CallUser(id: me, username: "erlan"), video: true), to: hub)
        let callId = try #require(caller.connection.ringingCallId)
        await caller.send(.hangup(callId: callId), to: hub)

        #expect(phone.connection.endReasons == [.cancelled])
        #expect(sink.records.last?.status == .missed)
    }

    @Test("Reconnecting within the grace period resumes the call on the new socket")
    func reconnectResumesCall() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        let callId = try await startSelfCall(hub, mac: mac, phone: phone)

        await phone.disconnect(from: hub)
        #expect(mac.connection.messages.contains(.callReconnecting(callId: callId)))

        // Same device id, new socket (e.g. switched from Wi-Fi to LTE).
        let phoneAgain = TestDevice(user: me, id: "iphone")
        await phoneAgain.connect(to: hub)

        #expect(mac.connection.messages.contains(.callResumed(callId: callId, peer: phone.peer, role: .caller, video: true)))
        #expect(phoneAgain.connection.messages.contains(.callResumed(callId: callId, peer: mac.peer, role: .callee, video: true)))

        let restart = SignalPayload(kind: .offer, sdp: "v=0 ice restart")
        await mac.send(.signal(callId: callId, signal: restart), to: hub)
        #expect(phoneAgain.connection.signals == [restart])
        #expect(mac.connection.endReasons.isEmpty)
    }

    @Test("Not reconnecting within the grace period ends the call")
    func graceExpires() async throws {
        let hub = makeHub(reconnectGrace: .milliseconds(50))
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        _ = try await startSelfCall(hub, mac: mac, phone: phone)

        await phone.disconnect(from: hub)

        #expect(await eventually { mac.connection.endReasons == [.connectionLost] })
        let record = try #require(sink.records.last)
        #expect(record.status == .completed)
        #expect(record.endReason == .connectionLost)
        #expect(record.duration != nil)
    }

    @Test("A newer socket from the same device replaces the stale one")
    func staleSocketReplaced() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        let callId = try await startSelfCall(hub, mac: mac, phone: phone)

        let phoneAgain = TestDevice(user: me, id: "iphone")
        await phoneAgain.connect(to: hub)
        #expect(phone.connection.closed)

        // The old socket's late close must not drop the device or the call.
        await phone.disconnect(from: hub)
        mac.connection.clear()
        let candidate = SignalPayload(kind: .candidate, candidate: .init(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0, usernameFragment: nil))
        await mac.send(.signal(callId: callId, signal: candidate), to: hub)

        #expect(phoneAgain.connection.signals == [candidate])
        #expect(mac.connection.endReasons.isEmpty)
        #expect(mac.connection.errorCodes.isEmpty)
    }

    @Test("Only the two parties of a call can signal into it")
    func outsidersCannotSignal() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        let callId = try await startSelfCall(hub, mac: mac, phone: phone)

        let stranger = TestDevice(user: friend, username: "friend", id: "pixel")
        await stranger.connect(to: hub)
        await stranger.send(.signal(callId: callId, signal: SignalPayload(kind: .offer, sdp: "v=0")), to: hub)
        await stranger.send(.hangup(callId: callId), to: hub)

        #expect(stranger.connection.errorCodes == [.callNotFound, .callNotFound])
        #expect(phone.connection.signals.isEmpty)
        #expect(mac.connection.endReasons.isEmpty)
    }

    @Test("Presence lists your online devices")
    func presence() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac", name: "MacBook")
        let phone = TestDevice(user: me, id: "iphone", name: "iPhone")
        await mac.connect(to: hub)
        await phone.connect(to: hub)

        #expect(mac.connection.messages.last == .presence(devices: [mac.peer, phone.peer]))

        await phone.disconnect(from: hub)
        #expect(mac.connection.messages.last == .presence(devices: [mac.peer]))
    }

    @Test("History records ringing, active and completed snapshots in order")
    func historySnapshots() async throws {
        let hub = makeHub()
        let mac = TestDevice(user: me, id: "mac")
        let phone = TestDevice(user: me, id: "iphone")
        let callId = try await startSelfCall(hub, mac: mac, phone: phone)
        await phone.send(.hangup(callId: callId), to: hub)

        #expect(sink.records.map(\.status) == [.ringing, .active, .completed])
        let record = try #require(sink.records.last)
        #expect(record.calleeDeviceId == "iphone")
        #expect(record.endReason == .hangup)
        #expect(mac.connection.endReasons == [.hangup])
    }
}

// MARK: - Wire Format Tests

@Suite("Signaling wire format")
struct SignalingMessageTests {
    @Test("Client messages decode from JSON")
    func decodeClientMessages() throws {
        let callId = UUID()
        let json = """
        {"type":"call.signal","callId":"\(callId)","signal":{"kind":"candidate","candidate":{"candidate":"candidate:1 1 udp","sdpMid":"0","sdpMLineIndex":0}}}
        """
        let message = try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
        guard case let .signal(decodedId, signal) = message else {
            Issue.record("Expected call.signal, got \(message)")
            return
        }
        #expect(decodedId == callId)
        #expect(signal.kind == .candidate)

        let invite = try JSONDecoder().decode(ClientMessage.self, from: Data(#"{"type":"call.invite","calleeEmail":"me@example.com"}"#.utf8))
        #expect(invite == .invite(calleeId: nil, calleeEmail: "me@example.com", video: true))
    }

    @Test("Invalid client messages are rejected")
    func rejectInvalidMessages() {
        let invalid = [
            #"{"type":"call.signal","callId":"\#(UUID())","signal":{"kind":"offer"}}"#,
            #"{"type":"call.invite","video":true}"#,
            #"{"type":"call.accept"}"#,
            #"{"type":"call.teleport"}"#,
        ]
        for json in invalid {
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ClientMessage.self, from: Data(json.utf8))
            }
        }
    }

    @Test("Server messages encode with a type discriminator")
    func encodeServerMessage() throws {
        let callId = UUID()
        let data = try JSONEncoder().encode(ServerMessage.callEnded(callId: callId, reason: .answeredElsewhere))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(object == ["type": "call.ended", "callId": callId.uuidString, "reason": "answered_elsewhere"])
    }

    @Test("TURN credentials follow the coturn REST scheme")
    func turnCredentials() throws {
        let provider = IceServerProvider(turnURLs: ["turn:turn.example.com:3478"], turnSecret: "secret", credentialTTL: 60)
        let userId = UUID()
        let servers = provider.servers(for: userId, now: Date(timeIntervalSince1970: 1_000))

        #expect(servers.count == 2)
        let turn = try #require(servers.last)
        #expect(turn.username == "1060:\(userId.uuidString)")
        #expect(turn.credential?.isEmpty == false)
    }
}
