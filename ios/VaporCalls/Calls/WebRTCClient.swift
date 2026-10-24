import AVFoundation
import CoreText
import UIKit
@preconcurrency import WebRTC

/// Everything WebRTC: camera/microphone tracks and one peer connection.
/// Negotiation steps are async wrappers around the callback API. WebRTC calls
/// its delegate on an internal thread, so the delegate methods are nonisolated,
/// copy what they need into Sendable values and hop to the main actor.
final class WebRTCClient: NSObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()

    var onIceCandidate: (IceCandidatePayload) -> Void = { _ in }
    var onConnectionState: (RTCPeerConnectionState) -> Void = { _ in }

    private(set) var localVideoTrack: RTCVideoTrack?
    private(set) var localAudioTrack: RTCAudioTrack?
    private(set) var remoteVideoTrack: RTCVideoTrack?
    private(set) var usingFrontCamera = true

    private var peerConnection: RTCPeerConnection?
    private var pendingCandidates: [IceCandidatePayload] = []
    private var videoSource: RTCVideoSource?
    private var cameraCapturer: RTCCameraVideoCapturer?
    private var syntheticCapturer: SyntheticFrameCapturer?

    // MARK: - Local media

    func startLocalMedia(video: Bool) {
        guard localAudioTrack == nil else { return }
        let factory = Self.factory
        let audioConstraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        localAudioTrack = factory.audioTrack(with: factory.audioSource(with: audioConstraints), trackId: "audio0")

        guard video else { return }
        let source = factory.videoSource()
        videoSource = source
        localVideoTrack = factory.videoTrack(with: source, trackId: "video0")

        #if targetEnvironment(simulator)
        // The simulator has no camera: send generated frames instead.
        let synthetic = SyntheticFrameCapturer(delegate: source)
        synthetic.start()
        syntheticCapturer = synthetic
        #else
        let capturer = RTCCameraVideoCapturer(delegate: source)
        cameraCapturer = capturer
        startCamera(front: true)
        #endif
    }

    func stopLocalMedia() {
        cameraCapturer?.stopCapture()
        cameraCapturer = nil
        syntheticCapturer?.stop()
        syntheticCapturer = nil
        localVideoTrack = nil
        localAudioTrack = nil
        videoSource = nil
        usingFrontCamera = true
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    func setCameraEnabled(_ enabled: Bool) {
        localVideoTrack?.isEnabled = enabled
    }

    func switchCamera() {
        guard cameraCapturer != nil else { return }
        startCamera(front: !usingFrontCamera)
    }

    private func startCamera(front: Bool) {
        guard let capturer = cameraCapturer else { return }
        let position: AVCaptureDevice.Position = front ? .front : .back
        guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position })
            ?? RTCCameraVideoCapturer.captureDevices().first else { return }

        // The format closest to 1280×720; WebRTC scales down when the network is poor.
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        let format = formats.min { a, b in
            let da = CMVideoFormatDescriptionGetDimensions(a.formatDescription)
            let db = CMVideoFormatDescriptionGetDimensions(b.formatDescription)
            return abs(Int(da.width) * Int(da.height) - 1280 * 720) < abs(Int(db.width) * Int(db.height) - 1280 * 720)
        }
        guard let format else { return }
        let maxFps = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        capturer.startCapture(with: device, format: format, fps: Int(min(maxFps, 30)))
        usingFrontCamera = device.position == .front
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        Log.info("Camera started", .webrtc, ["camera": front ? "front" : "back", "format": "\(size.width)×\(size.height)", "fps": "\(Int(min(maxFps, 30)))"])
    }

    // MARK: - Peer connection

    func createPeerConnection(iceServers: [IceServerConfig]) {
        guard peerConnection == nil else { return }
        let config = RTCConfiguration()
        config.iceServers = iceServers.map { RTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
        guard let connection = Self.factory.peerConnection(with: config, constraints: constraints, delegate: self) else { return }
        if let localAudioTrack { _ = connection.add(localAudioTrack, streamIds: ["local"]) }
        if let localVideoTrack { _ = connection.add(localVideoTrack, streamIds: ["local"]) }
        preferH264(on: connection)
        peerConnection = connection
        pendingCandidates = []
        Log.info("Peer connection created", .webrtc, ["iceServers": "\(iceServers.count)"])
    }

    /// Prefer H.264: iPhones and Macs encode and decode it in hardware, so the
    /// picture stays sharp without the CPU throttling resolution. The other
    /// codecs stay in the list as fallbacks for peers without H.264.
    private func preferH264(on connection: RTCPeerConnection) {
        let codecs = Self.factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
        let isH264 = { (codec: RTCRtpCodecCapability) in codec.name.caseInsensitiveCompare("H264") == .orderedSame }
        guard codecs.contains(where: isH264) else { return }
        let ordered = codecs.filter(isH264) + codecs.filter { !isH264($0) }
        for transceiver in connection.transceivers where transceiver.mediaType == .video {
            // Swift keeps an `error: ()` label on the throwing variant because the
            // deprecated non-throwing overload already took the plain name.
            do {
                try transceiver.setCodecPreferences(ordered, error: ())
            } catch {
                Log.warning("Could not prefer H.264: \(error.localizedDescription)", .webrtc)
            }
        }
    }

    /// Lets the encoder use up to 2.5 Mbps (720p at 30 fps) instead of a conservative cap.
    /// Encodings exist only after the local description is set.
    private func applyVideoEncodingLimits(on connection: RTCPeerConnection) {
        guard let sender = connection.senders.first(where: { $0.track?.kind == kRTCMediaStreamTrackKindVideo }) else { return }
        let parameters = sender.parameters
        guard !parameters.encodings.isEmpty else { return }
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = 2_500_000
            encoding.maxFramerate = 30
        }
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        sender.parameters = parameters
    }

    /// A snapshot of the connection's statistics (nil without a connection).
    func statistics() async -> MediaStats? {
        guard let connection = peerConnection else { return nil }
        return await withCheckedContinuation { continuation in
            connection.statistics { @Sendable report in
                continuation.resume(returning: MediaStats(report: report))
            }
        }
    }

    func closePeerConnection() {
        peerConnection?.close()
        peerConnection = nil
        remoteVideoTrack = nil
        pendingCandidates = []
    }

    var hasPeerConnection: Bool { peerConnection != nil }

    func makeOffer(iceRestart: Bool = false) async throws -> String {
        guard let connection = peerConnection else { throw WebRTCError.noConnection }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true", "IceRestart": iceRestart ? "true" : "false"],
            optionalConstraints: nil
        )
        let sdp: String = try await withCheckedThrowingContinuation { continuation in
            connection.offer(for: constraints) { @Sendable description, error in
                if let description { continuation.resume(returning: description.sdp) }
                else { continuation.resume(throwing: error ?? WebRTCError.negotiation) }
            }
        }
        try await setLocal(RTCSessionDescription(type: .offer, sdp: sdp), on: connection)
        return sdp
    }

    /// Applies the remote offer and returns our answer.
    func answer(offer sdp: String) async throws -> String {
        guard let connection = peerConnection else { throw WebRTCError.noConnection }
        try await setRemote(RTCSessionDescription(type: .offer, sdp: sdp), on: connection)
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": "true"],
            optionalConstraints: nil
        )
        let answer: String = try await withCheckedThrowingContinuation { continuation in
            connection.answer(for: constraints) { @Sendable description, error in
                if let description { continuation.resume(returning: description.sdp) }
                else { continuation.resume(throwing: error ?? WebRTCError.negotiation) }
            }
        }
        try await setLocal(RTCSessionDescription(type: .answer, sdp: answer), on: connection)
        return answer
    }

    func apply(answer sdp: String) async throws {
        guard let connection = peerConnection else { throw WebRTCError.noConnection }
        try await setRemote(RTCSessionDescription(type: .answer, sdp: sdp), on: connection)
    }

    func add(candidate: IceCandidatePayload) {
        guard let connection = peerConnection else { return }
        // Candidates can arrive before the remote description; hold them until then.
        guard connection.remoteDescription != nil else {
            pendingCandidates.append(candidate)
            return
        }
        connection.add(RTCIceCandidate(sdp: candidate.candidate, sdpMLineIndex: candidate.sdpMLineIndex ?? 0, sdpMid: candidate.sdpMid)) { @Sendable _ in }
    }

    private func setLocal(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setLocalDescription(description) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        applyVideoEncodingLimits(on: connection)
    }

    private func setRemote(_ description: RTCSessionDescription, on connection: RTCPeerConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.setRemoteDescription(description) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        // With Unified Plan the remote track exists as soon as the description is set.
        remoteVideoTrack = connection.transceivers
            .first { $0.mediaType == .video }?
            .receiver.track as? RTCVideoTrack
        let pending = pendingCandidates
        pendingCandidates = []
        pending.forEach(add(candidate:))
    }
}

enum WebRTCError: LocalizedError {
    case noConnection
    case negotiation

    var errorDescription: String? {
        switch self {
        case .noConnection: "Соединение не создано"
        case .negotiation: "Не удалось договориться о звонке"
        }
    }
}

// MARK: - RTCPeerConnectionDelegate

extension WebRTCClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        let payload = IceCandidatePayload(candidate: candidate.sdp, sdpMid: candidate.sdpMid, sdpMLineIndex: candidate.sdpMLineIndex)
        let source = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection.map({ ObjectIdentifier($0) }) == source else { return }
            self.onIceCandidate(payload)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        Log.info("Peer connection: \(newState.name)", .webrtc)
        let source = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection.map({ ObjectIdentifier($0) }) == source else { return }
            self.onConnectionState(newState)
        }
    }

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        Log.debug("ICE: \(newState.name)", .webrtc)
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

// MARK: - State names for logs

extension RTCPeerConnectionState {
    nonisolated var name: String {
        switch self {
        case .new: "new"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

extension RTCIceConnectionState {
    nonisolated var name: String {
        switch self {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown(\(rawValue))"
        }
    }
}

// MARK: - Statistics

/// The parts of a WebRTC stats report that explain call quality.
nonisolated struct MediaStats: Sendable {
    struct Video: Sendable {
        var width = 0
        var height = 0
        var fps = 0.0
        var bytes = 0.0
        var codec: String?
        /// Why the encoder lowered quality: "bandwidth", "cpu", "other" or "none".
        var limitation: String?
        var packetsLost = 0.0
        var packetsReceived = 0.0
    }

    var sent: Video?
    var received: Video?
    var rttMs: Double?
    var availableOutgoingKbps: Double?
    /// Candidate types of the active path, e.g. "host ↔ srflx" (relay = through TURN).
    var path: String?
    let timestamp = Date()

    init(report: RTCStatisticsReport) {
        let all = Array(report.statistics.values)
        func number(_ stat: RTCStatistics, _ key: String) -> Double? { (stat.values[key] as? NSNumber)?.doubleValue }
        func text(_ stat: RTCStatistics, _ key: String) -> String? { stat.values[key] as? String }
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        func codecName(_ stat: RTCStatistics) -> String? {
            text(stat, "codecId").flatMap { byId[$0] }.flatMap { text($0, "mimeType") }?.replacingOccurrences(of: "video/", with: "")
        }

        for stat in all {
            switch stat.type {
            case "outbound-rtp" where text(stat, "kind") == "video":
                sent = Video(width: Int(number(stat, "frameWidth") ?? 0), height: Int(number(stat, "frameHeight") ?? 0),
                             fps: number(stat, "framesPerSecond") ?? 0, bytes: number(stat, "bytesSent") ?? 0,
                             codec: codecName(stat), limitation: text(stat, "qualityLimitationReason"))
            case "inbound-rtp" where text(stat, "kind") == "video":
                received = Video(width: Int(number(stat, "frameWidth") ?? 0), height: Int(number(stat, "frameHeight") ?? 0),
                                 fps: number(stat, "framesPerSecond") ?? 0, bytes: number(stat, "bytesReceived") ?? 0,
                                 codec: codecName(stat), packetsLost: number(stat, "packetsLost") ?? 0,
                                 packetsReceived: number(stat, "packetsReceived") ?? 0)
            case "candidate-pair" where text(stat, "state") == "succeeded" && (stat.values["nominated"] as? NSNumber)?.boolValue == true:
                rttMs = number(stat, "currentRoundTripTime").map { $0 * 1000 }
                availableOutgoingKbps = number(stat, "availableOutgoingBitrate").map { $0 / 1000 }
                let local = text(stat, "localCandidateId").flatMap { byId[$0] }.flatMap { text($0, "candidateType") }
                let remote = text(stat, "remoteCandidateId").flatMap { byId[$0] }.flatMap { text($0, "candidateType") }
                if let local, let remote { path = "\(local) ↔ \(remote)" }
            default:
                break
            }
        }
    }
}

// MARK: - Simulator camera

/// Generates a moving color frame with a caption, standing in for a camera in the simulator.
///
/// Frames are drawn on a private queue into buffers from a pool: creating an
/// IOSurface per frame is a synchronous XPC call, and doing that 15 times a
/// second on the main thread deadlocked the simulator's audio start-up.
/// Nonisolated because it subclasses an Objective-C class; all state lives on `queue`.
nonisolated final class SyntheticFrameCapturer: RTCVideoCapturer, @unchecked Sendable {
    private let width = 480
    private let height = 640
    private let queue = DispatchQueue(label: "VaporCalls.synthetic-camera")
    private var timer: DispatchSourceTimer?
    private var pool: CVPixelBufferPool?
    private var tick = 0

    func start() {
        queue.async { [self] in
            guard timer == nil else { return }
            // IOSurface + Metal compatible, so the local preview can render the frames too.
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            ]
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(66))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            pool = nil
        }
    }

    private func emitFrame() {
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return }

        CVPixelBufferLockBaseAddress(buffer, [])
        if let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) {
            tick += 1
            context.setFillColor(Self.color(hue: Double(tick % 360) / 360))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            draw("iOS Simulator", at: CGPoint(x: 28, y: CGFloat(height) / 2 + 12), in: context)
            draw("\(tick)", at: CGPoint(x: 28, y: CGFloat(height) / 2 - 44), in: context)
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])

        let frame = RTCVideoFrame(
            buffer: RTCCVPixelBuffer(pixelBuffer: buffer),
            rotation: ._0,
            timeStampNs: Int64(DispatchTime.now().uptimeNanoseconds)
        )
        delegate?.capturer(self, didCapture: frame)
    }

    /// CoreText instead of UIKit drawing: UIKit is main-thread only.
    private func draw(_ text: String, at point: CGPoint, in context: CGContext) {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func color(hue: Double) -> CGColor {
        // HSV → RGB with saturation 0.6 and value 0.7.
        let s = 0.6, v = 0.7
        let h = hue * 6
        let f = h - floor(h)
        let p = v * (1 - s), q = v * (1 - s * f), t = v * (1 - s * (1 - f))
        let (r, g, b): (Double, Double, Double) = switch Int(h) % 6 {
        case 0: (v, t, p)
        case 1: (q, v, p)
        case 2: (p, v, t)
        case 3: (p, q, v)
        case 4: (t, p, v)
        default: (v, p, q)
        }
        return CGColor(red: r, green: g, blue: b, alpha: 1)
    }
}
