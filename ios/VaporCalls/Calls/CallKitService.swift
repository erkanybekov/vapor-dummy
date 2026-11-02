import AVFoundation
import CallKit
@preconcurrency import WebRTC

/// The system call UI. Incoming calls ring like a regular phone call (full
/// screen when locked, mirrored to Apple Watch), the call shows in the status
/// bar, and calls land in Phone → Recents.
///
/// With CallKit, the system owns the audio session: WebRTC audio starts only
/// once CallKit activates it (`didActivate`), hence `useManualAudio`.
final class CallKitService: NSObject {
    /// CallKit's UI does not run in the simulator; there the app uses its own incoming screen.
    static var isAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    var onAnswer: (UUID) -> Void = { _ in }
    var onEnd: (UUID) -> Void = { _ in }
    var onMute: (UUID, Bool) -> Void = { _, _ in }
    var onReset: () -> Void = {}

    private let provider: CXProvider
    private let controller = CXCallController()
    /// Whether each known call is a video call (picks speaker vs earpiece).
    private var videoByCall: [UUID: Bool] = [:]

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic, .emailAddress]
        configuration.includesCallsInRecents = true
        provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil) // main queue

        let audio = RTCAudioSession.sharedInstance()
        audio.useManualAudio = true
        audio.isAudioEnabled = false
    }

    // MARK: - Reporting to the system

    func reportIncoming(id: UUID, name: String, video: Bool) async throws {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: name)
        update.localizedCallerName = name
        update.hasVideo = video
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        videoByCall[id] = video
        try await provider.reportNewIncomingCall(with: id, update: update)
    }

    func startOutgoing(id: UUID, name: String, video: Bool) async throws {
        let action = CXStartCallAction(call: id, handle: CXHandle(type: .generic, value: name))
        action.isVideo = video
        videoByCall[id] = video
        try await controller.request(CXTransaction(action: action))
    }

    func reportConnected(id: UUID, outgoing: Bool) {
        if outgoing { provider.reportOutgoingCall(with: id, connectedAt: Date()) }
    }

    /// The user hung up in our UI: ask the system, which then calls `onEnd`.
    func requestEnd(id: UUID) async throws {
        try await controller.request(CXTransaction(action: CXEndCallAction(call: id)))
    }

    func requestMute(id: UUID, muted: Bool) async throws {
        try await controller.request(CXTransaction(action: CXSetMutedCallAction(call: id, muted: muted)))
    }

    /// The call ended without the user touching CallKit (remote hang-up, timeout...).
    func reportEnded(id: UUID, reason: CXCallEndedReason) {
        Log.info("Report ended", .callkit, ["reason": "\(reason.rawValue)"])
        videoByCall[id] = nil
        provider.reportCall(with: id, endedAt: nil, reason: reason)
    }

    private func configureAudioSession(video: Bool) {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        // Video calls play through the speaker like FaceTime; audio calls use the earpiece.
        try? session.setCategory(
            .playAndRecord,
            mode: video ? .videoChat : .voiceChat,
            options: video ? [.allowBluetoothHFP, .defaultToSpeaker] : [.allowBluetoothHFP]
        )
    }
}

// MARK: - CXProviderDelegate (delivered on the main queue)

extension CallKitService: @preconcurrency CXProviderDelegate {
    func providerDidReset(_ provider: CXProvider) {
        Log.warning("Provider reset", .callkit)
        onReset()
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Log.info("Start call action", .callkit, ["video": "\(action.isVideo)"])
        configureAudioSession(video: action.isVideo)
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Log.info("Answer action", .callkit)
        configureAudioSession(video: videoByCall[action.callUUID] ?? true)
        onAnswer(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Log.info("End action", .callkit)
        videoByCall[action.callUUID] = nil
        onEnd(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute(action.callUUID, action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Log.info("Audio session activated", .callkit, ["route": audioSession.currentRoute.outputs.first?.portName ?? "?"])
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Log.info("Audio session deactivated", .callkit)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
    }
}
