import AVFoundation
import CallKit
import Foundation
import Observation
@preconcurrency import WebRTC

/// The call state machine for this device. Same behaviour as the web app's
/// CallManager (web/src/calls/CallManager.ts): the server assigns roles, the
/// caller sends the SDP offer, both sides trickle ICE candidates, and media
/// flows directly between the devices. On a real iPhone, CallKit provides the
/// ringing screen and owns the audio session.
@Observable
final class CallManager {
    enum Phase: Equatable {
        case dialing, ringing, incoming, connecting, active
    }

    enum Trouble: Equatable {
        case reconnecting, poorNetwork
    }

    struct ActiveCall: Equatable {
        /// Server call id; nil until the server acknowledges our invite.
        var id: UUID?
        /// The id CallKit knows the call by (the server id for incoming calls).
        let localId: UUID
        var role: CallRole
        var phase: Phase
        var video: Bool
        var peerName: String
        var peerDevice: String?
        var ringingDevices: Int?
        var connectedAt: Date?
        var trouble: Trouble?
    }

    enum Target {
        case email(String)
        case user(id: UUID, name: String)
    }

    // MARK: Observable state

    private(set) var connection: SignalingClient.State = .offline
    private(set) var devices: [CallPeer] = []
    private(set) var call: ActiveCall?
    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private(set) var muted = false
    private(set) var cameraOff = false
    private(set) var usingFrontCamera = true
    /// Incremented whenever a call ends, so history views know to reload.
    private(set) var endedCalls = 0
    /// A short message for the user (shown as a toast).
    var notice: String?
    /// Live media statistics while a call is connected.
    private(set) var quality: CallQuality?

    /// Whether incoming calls ring through CallKit (real device) or the app's own screen (simulator).
    let usesCallKit = CallKitService.isAvailable

    // MARK: Collaborators

    private let signaling: SignalingClient
    private let webrtc = WebRTCClient()
    private let callKit: CallKitService?
    private var iceServers = [IceServerConfig(urls: ["stun:stun.l.google.com:19302"], username: nil, credential: nil)]
    /// Negotiation steps run strictly one after another.
    private var queueTail: Task<Void, Never>?
    private var inviteSent = false
    /// We hung up before the server told us the call id: hang up as soon as it does.
    private var cancelPendingInvite = false
    private var qualityTask: Task<Void, Never>?

    init(api: APIClient) {
        signaling = SignalingClient(deviceId: DeviceIdentity.id, deviceName: DeviceIdentity.name) { force in
            try await api.accessToken(forceRefresh: force)
        }
        callKit = CallKitService.isAvailable ? CallKitService() : nil

        signaling.onMessage = { [weak self] message in self?.handle(message) }
        signaling.onState = { [weak self] state in self?.connection = state }
        webrtc.onIceCandidate = { [weak self] candidate in self?.sendSignal(SignalPayload(kind: .candidate, candidate: candidate)) }
        webrtc.onConnectionState = { [weak self] state in self?.peerConnectionChanged(state) }

        callKit?.onAnswer = { [weak self] id in
            guard let self, call?.localId == id else { return }
            Task { await self.accept() }
        }
        callKit?.onEnd = { [weak self] id in
            guard let self, call?.localId == id else { return }
            performHangup()
        }
        callKit?.onMute = { [weak self] id, muted in
            guard let self, call?.localId == id else { return }
            setMuted(muted)
        }
        callKit?.onReset = { [weak self] in self?.endLocally() }
    }

    // MARK: - Lifecycle

    func start() { signaling.start() }

    func stop() {
        if let call { callKit?.reportEnded(id: call.localId, reason: .failed) }
        endLocally()
        signaling.stop()
    }

    /// The app came back to the foreground: reconnect right away.
    func wake() { signaling.wake() }

    // MARK: - User actions

    func startCall(to target: Target, video: Bool) async {
        guard call == nil else { return }
        guard connection == .online else {
            notice = "Нет связи с сервером звонков"
            return
        }
        let peerName: String = switch target {
        case let .email(email): email
        case let .user(_, name): name
        }
        let localId = UUID()
        call = ActiveCall(id: nil, localId: localId, role: .caller, phase: .dialing, video: video, peerName: peerName)
        Log.info("Calling \(peerName)", .call, ["video": "\(video)"])

        guard await requestMediaAccess(video: video), call?.localId == localId else {
            endLocally()
            return
        }
        if let callKit {
            do {
                try await callKit.startOutgoing(id: localId, name: peerName, video: video)
            } catch {
                Log.error(error, .callkit, "Start call transaction")
                notice = "Система не дала начать звонок"
                endLocally()
                return
            }
        }
        guard call?.localId == localId else { return } // hung up meanwhile

        startLocalMedia(video: video)
        let invite: ClientMessage = switch target {
        case let .email(email): .invite(calleeEmail: email, calleeId: nil, video: video)
        case let .user(id, _): .invite(calleeEmail: nil, calleeId: id, video: video)
        }
        guard signaling.send(invite) else {
            notice = "Нет связи с сервером звонков"
            callKit?.reportEnded(id: localId, reason: .failed)
            endLocally()
            return
        }
        inviteSent = true
    }

    func accept() async {
        guard let current = call, let callId = current.id, current.phase == .incoming else { return }
        Log.info("Answering", .call, ["call": String(callId.uuidString.prefix(8))])
        call?.phase = .connecting
        guard await requestMediaAccess(video: current.video), call?.id == callId else {
            signaling.send(.decline(callId: callId))
            callKit?.reportEnded(id: current.localId, reason: .failed)
            endLocally()
            return
        }
        startLocalMedia(video: current.video)
        // Ready before the caller's offer can arrive.
        webrtc.createPeerConnection(iceServers: iceServers)
        signaling.send(.accept(callId: callId))
    }

    func decline() {
        hangup()
    }

    /// Hang up from our own UI. With CallKit the system is asked first and calls back.
    func hangup() {
        guard let call else { return }
        if let callKit {
            Task {
                do {
                    try await callKit.requestEnd(id: call.localId)
                } catch {
                    performHangup() // CallKit did not know the call: end it ourselves
                }
            }
        } else {
            performHangup()
        }
    }

    func toggleMute() {
        let next = !muted
        if let callKit, let call {
            Task {
                do {
                    try await callKit.requestMute(id: call.localId, muted: next)
                } catch {
                    setMuted(next)
                }
            }
        } else {
            setMuted(next)
        }
    }

    func toggleCamera() {
        cameraOff.toggle()
        webrtc.setCameraEnabled(!cameraOff)
    }

    func flipCamera() {
        webrtc.switchCamera()
        usingFrontCamera = webrtc.usingFrontCamera
    }

    // MARK: - Server messages

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .hello(_, _, servers):
            if !servers.isEmpty { iceServers = servers }

        case let .presence(devices):
            self.devices = devices

        case let .ringing(callId, callee, count):
            if cancelPendingInvite {
                cancelPendingInvite = false
                signaling.send(.hangup(callId: callId))
                return
            }
            guard var current = call, current.role == .caller, current.id == nil || current.id == callId else { return }
            current.id = callId
            current.peerName = callee.username
            current.ringingDevices = count
            if current.phase == .dialing { current.phase = .ringing }
            call = current

        case let .incoming(callId, caller, video):
            guard call == nil else { return } // busy here; the account's other devices keep ringing
            call = ActiveCall(id: callId, localId: callId, role: .callee, phase: .incoming, video: video,
                              peerName: caller.username, peerDevice: caller.deviceName)
            Log.info("Incoming call from \(caller.username)", .call, ["device": caller.deviceName, "video": "\(video)"])
            if let callKit {
                Task {
                    do {
                        try await callKit.reportIncoming(id: callId, name: caller.username, video: video)
                    } catch {
                        // Do Not Disturb, blocked, or another call in progress.
                        Log.warning("CallKit refused the incoming call: \(error.localizedDescription)", .callkit)
                        if call?.id == callId { performHangup() }
                    }
                }
            }

        case let .accepted(callId, peer, role, _):
            guard call?.id == callId else { return }
            call?.phase = .connecting
            call?.peerName = peer.username
            call?.peerDevice = peer.deviceName
            if role == .caller { enqueue { try await self.negotiate() } }

        case let .resumed(callId, peer, role, video):
            enqueue { await self.resume(callId: callId, peer: peer, role: role, video: video) }

        case let .reconnecting(callId):
            if call?.id == callId { call?.trouble = .reconnecting }

        case let .signal(callId, _, signal):
            guard call?.id == callId else { return }
            enqueue { try await self.apply(signal) }

        case let .ended(callId, reason):
            guard let current = call else {
                cancelPendingInvite = false
                return
            }
            if let id = current.id, id != callId { return }
            if current.id == nil, current.role != .caller { return }
            if reason != .hangup { notice = reason.text }
            Log.info("Call ended: \(reason.rawValue)", .call)
            callKit?.reportEnded(id: current.localId, reason: Self.callKitReason(for: reason, role: current.role))
            endLocally()

        case let .error(code, message, _):
            if code == "peer_unavailable" { return } // the peer is reconnecting
            Log.warning("Server error \(code): \(message)", .signaling)
            notice = SignalingErrorText.text(for: code, fallback: message)
            if let current = call, current.id == nil, current.role == .caller {
                callKit?.reportEnded(id: current.localId, reason: .failed)
                endLocally()
            }
            if call == nil { cancelPendingInvite = false }

        case .pong, .unknown:
            break
        }
    }

    private static func callKitReason(for reason: CallEndReason, role: CallRole) -> CXCallEndedReason {
        switch reason {
        case .answeredElsewhere: .answeredElsewhere
        case .declined: role == .callee ? .declinedElsewhere : .remoteEnded
        case .timeout, .busy, .unavailable: .unanswered
        case .connectionLost: .failed
        case .hangup, .cancelled: .remoteEnded
        }
    }

    // MARK: - WebRTC

    private func enqueue(_ step: @escaping () async throws -> Void) {
        let previous = queueTail
        queueTail = Task {
            await previous?.value
            do {
                try await step()
            } catch {
                Log.error(error, .webrtc, "Negotiation step")
            }
        }
    }

    private func startLocalMedia(video: Bool) {
        webrtc.startLocalMedia(video: video)
        localVideoTrack = webrtc.localVideoTrack
        usingFrontCamera = webrtc.usingFrontCamera
    }

    private func negotiate(iceRestart: Bool = false) async throws {
        guard call?.id != nil else { return }
        webrtc.createPeerConnection(iceServers: iceServers)
        let sdp = try await webrtc.makeOffer(iceRestart: iceRestart)
        sendSignal(SignalPayload(kind: .offer, sdp: sdp))
    }

    private func apply(_ signal: SignalPayload) async throws {
        guard call?.id != nil, webrtc.localAudioTrack != nil else { return }
        webrtc.createPeerConnection(iceServers: iceServers)
        switch signal.kind {
        case .offer:
            guard let sdp = signal.sdp else { return }
            let answer = try await webrtc.answer(offer: sdp)
            sendSignal(SignalPayload(kind: .answer, sdp: answer))
        case .answer:
            guard let sdp = signal.sdp else { return }
            try await webrtc.apply(answer: sdp)
        case .candidate:
            if let candidate = signal.candidate { webrtc.add(candidate: candidate) }
        }
        remoteVideoTrack = webrtc.remoteVideoTrack
    }

    /// After a signaling reconnect both sides start a fresh peer connection and the caller re-offers.
    private func resume(callId: UUID, peer: CallPeer, role: CallRole, video: Bool) async {
        if let current = call, current.id != callId { return }
        if call == nil {
            call = ActiveCall(id: callId, localId: callId, role: role, phase: .connecting, video: video,
                              peerName: peer.username, peerDevice: peer.deviceName)
        } else {
            call?.phase = .connecting
            call?.trouble = nil
        }
        if webrtc.localAudioTrack == nil {
            guard await requestMediaAccess(video: video) else { return }
            startLocalMedia(video: video)
        }
        webrtc.closePeerConnection()
        remoteVideoTrack = nil
        webrtc.createPeerConnection(iceServers: iceServers)
        if role == .caller { try? await negotiate() }
    }

    private func sendSignal(_ signal: SignalPayload) {
        guard let callId = call?.id else { return }
        signaling.send(.signal(callId: callId, signal: signal))
    }

    private func peerConnectionChanged(_ state: RTCPeerConnectionState) {
        guard let current = call else { return }
        switch state {
        case .connected:
            if current.phase != .active {
                callKit?.reportConnected(id: current.localId, outgoing: current.role == .caller)
                Log.info("Media connected", .call)
            }
            startQualityMonitor()
            call?.phase = .active
            call?.connectedAt = current.connectedAt ?? Date()
            call?.trouble = nil
            remoteVideoTrack = webrtc.remoteVideoTrack
        case .disconnected:
            call?.trouble = .poorNetwork
        case .failed:
            call?.trouble = .reconnecting
            // The caller drives renegotiation: restart ICE on the same connection.
            if current.role == .caller { enqueue { try await self.negotiate(iceRestart: true) } }
        default:
            break
        }
    }

    /// Samples WebRTC stats every 2 s for the on-screen panel and logs a summary every 10 s.
    private func startQualityMonitor() {
        guard qualityTask == nil else { return }
        qualityTask = Task { [weak self] in
            var previous: MediaStats?
            var sample = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                guard !Task.isCancelled, let stats = await webrtc.statistics() else { continue }
                let quality = CallQuality(current: stats, previous: previous)
                self.quality = quality
                if sample % 5 == 0 { Log.info(quality.summary, .quality) }
                if let limitation = quality.sent?.limitation, limitation != previous?.sent?.limitation, limitation != "none" {
                    Log.warning("Encoder limited by \(limitation)", .quality)
                }
                previous = stats
                sample += 1
            }
        }
    }

    private func setMuted(_ value: Bool) {
        muted = value
        webrtc.setMicrophoneEnabled(!value)
    }

    private func requestMediaAccess(video: Bool) async -> Bool {
        let microphone = await AVAudioApplication.requestRecordPermission()
        let camera = video ? await AVCaptureDevice.requestAccess(for: .video) : true
        if !microphone || !camera {
            Log.warning("Media permission denied", .call, ["microphone": "\(microphone)", "camera": "\(camera)"])
            notice = "Нет доступа к камере или микрофону: разрешите в Настройках"
            return false
        }
        return true
    }

    // MARK: - Ending

    /// Ends the call on our side and tells the server (used after CallKit agreed, or without CallKit).
    private func performHangup() {
        guard let current = call else { return }
        if let id = current.id {
            signaling.send(current.phase == .incoming ? .decline(callId: id) : .hangup(callId: id))
        } else if inviteSent {
            cancelPendingInvite = true
        }
        endLocally()
    }

    private func endLocally() {
        let hadCall = call != nil
        qualityTask?.cancel()
        qualityTask = nil
        quality = nil
        webrtc.closePeerConnection()
        webrtc.stopLocalMedia()
        queueTail = nil
        inviteSent = false
        call = nil
        localVideoTrack = nil
        remoteVideoTrack = nil
        muted = false
        cameraOff = false
        usingFrontCamera = true
        if hadCall { endedCalls += 1 }
    }
}

// MARK: - Call quality

/// What the call screen's stats panel shows; bitrates come from two consecutive samples.
struct CallQuality: Equatable {
    struct Video: Equatable {
        var width: Int
        var height: Int
        var fps: Int
        var kbps: Int
        var codec: String?
        var limitation: String?

        var resolution: String { width > 0 ? "\(width)×\(height)" : "—" }
    }

    var sent: Video?
    var received: Video?
    var rttMs: Int?
    var lossPercent: Double?
    var path: String?

    init(current: MediaStats, previous: MediaStats?) {
        let seconds = previous.map { current.timestamp.timeIntervalSince($0.timestamp) } ?? 0
        func kbps(_ now: Double?, _ before: Double?) -> Int {
            guard let now, let before, seconds > 0 else { return 0 }
            return max(0, Int((now - before) * 8 / seconds / 1000))
        }
        if let out = current.sent {
            sent = Video(width: out.width, height: out.height, fps: Int(out.fps.rounded()),
                         kbps: kbps(out.bytes, previous?.sent?.bytes), codec: out.codec, limitation: out.limitation)
        }
        if let inbound = current.received {
            received = Video(width: inbound.width, height: inbound.height, fps: Int(inbound.fps.rounded()),
                             kbps: kbps(inbound.bytes, previous?.received?.bytes), codec: inbound.codec)
            let total = inbound.packetsLost + inbound.packetsReceived
            lossPercent = total > 0 ? inbound.packetsLost / total * 100 : nil
        }
        rttMs = current.rttMs.map { Int($0.rounded()) }
        path = current.path
    }

    var summary: String {
        var parts: [String] = []
        if let sent { parts.append("↑ \(sent.resolution) \(sent.fps)fps \(sent.kbps)kbps \(sent.codec ?? "?") limit=\(sent.limitation ?? "?")") }
        if let received { parts.append("↓ \(received.resolution) \(received.fps)fps \(received.kbps)kbps \(received.codec ?? "?")") }
        if let rttMs { parts.append("rtt \(rttMs)ms") }
        if let lossPercent { parts.append(String(format: "loss %.1f%%", lossPercent)) }
        if let path { parts.append(path) }
        return parts.joined(separator: " · ")
    }
}
