import Foundation
import Logging

// MARK: - Call Hub
//
// In-memory signaling state machine: which devices are online, which calls are
// ringing or active, and where to relay WebRTC negotiation. The server never
// touches audio/video; it only introduces the two devices to each other.
//
// Every method is synchronous inside the actor, so state is never observed
// half-updated (no re-entrancy across `await`). Side effects are fire-and-forget:
// socket writes are enqueued by the connection, history writes by `onRecord`.
//
// State lives in this process, so the backend must run as a single instance.
// Running several instances needs a shared bus (e.g. Redis pub/sub) between them.

actor CallHub {
    struct Configuration: Sendable {
        /// How long an unanswered call rings before ending with `.timeout`.
        var ringTimeout: Duration = .seconds(30)
        /// How long a party of a call may stay disconnected before the call ends.
        var reconnectGrace: Duration = .seconds(15)
        /// Upper bound on simultaneously connected devices per account.
        var maxDevicesPerUser = 10
    }

    /// What a connected device can ask for. Invite targets are resolved to a
    /// user before they reach the hub.
    enum Command: Sendable {
        case invite(callee: CallUser, video: Bool)
        case accept(callId: UUID)
        case decline(callId: UUID)
        case hangup(callId: UUID)
        case signal(callId: UUID, signal: SignalPayload)
    }

    struct DeviceKey: Hashable, Sendable {
        let userId: UUID
        let deviceId: String
    }

    private struct Device {
        var peer: CallPeer
        /// nil while the device is offline but still holds a call open during the grace period.
        var connection: (any SignalingConnection)?
        /// The call this device is a party of: as caller, or as the callee device that answered.
        var callId: UUID?
    }

    private struct Call {
        var record: CallRecord
        let caller: DeviceKey
        let callee: CallUser
        /// The callee device that answered; nil while ringing.
        var answeredBy: DeviceKey?
        /// Callee devices currently ringing; emptied once someone answers.
        var ringing: Set<DeviceKey>
        var ringTimer: Task<Void, Never>?
        var graceTimers: [DeviceKey: Task<Void, Never>] = [:]

        func otherParty(of key: DeviceKey) -> DeviceKey? {
            if key == caller { return answeredBy }
            if key == answeredBy { return caller }
            return nil
        }

        func role(of key: DeviceKey) -> CallRole {
            key == caller ? .caller : .callee
        }
    }

    private let configuration: Configuration
    private let logger: Logger
    private let onRecord: @Sendable (CallRecord) -> Void

    private var devices: [DeviceKey: Device] = [:]
    private var calls: [UUID: Call] = [:]

    init(
        configuration: Configuration = .init(),
        logger: Logger = Logger(label: "call-hub"),
        onRecord: @escaping @Sendable (CallRecord) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.logger = logger
        self.onRecord = onRecord
    }

    // MARK: - Connections

    func connect(_ connection: any SignalingConnection, peer: CallPeer, iceServers: [IceServer]) {
        let key = DeviceKey(userId: peer.userId, deviceId: peer.deviceId)

        if var device = devices[key] {
            // Same device again (network switch, app relaunch): replace the stale
            // socket and keep its call alive.
            if let stale = device.connection, stale !== connection {
                stale.close()
            }
            device.connection = connection
            device.peer = peer
            devices[key] = device
        } else {
            let connected = devices.keys.filter { $0.userId == peer.userId }.count
            guard connected < configuration.maxDevicesPerUser else {
                connection.send(.error(code: .tooManyDevices, message: "Too many devices connected to this account", callId: nil))
                connection.close()
                return
            }
            devices[key] = Device(peer: peer, connection: connection, callId: nil)
        }

        connection.send(.hello(userId: peer.userId, deviceId: peer.deviceId, iceServers: iceServers))
        restoreCallState(for: key)
        broadcastPresence(for: peer.userId)
        logger.info("Device connected", metadata: ["user": "\(peer.userId)", "device": "\(peer.deviceId)"])
    }

    func disconnect(_ connection: any SignalingConnection, userId: UUID, deviceId: String) {
        let key = DeviceKey(userId: userId, deviceId: deviceId)
        // Ignore sockets that were already replaced by a newer one from the same device.
        guard devices[key]?.connection === connection else { return }

        let ringingHere = calls.filter { $0.value.ringing.contains(key) }.map(\.key)
        for callId in ringingHere {
            stopRinging(key, callId: callId)
        }

        if let callId = devices[key]?.callId, calls[callId] != nil {
            devices[key]?.connection = nil
            startGraceTimer(for: key, callId: callId)
        } else {
            devices[key] = nil
        }
        broadcastPresence(for: userId)
        logger.info("Device disconnected", metadata: ["user": "\(userId)", "device": "\(deviceId)"])
    }

    // MARK: - Commands

    func handle(_ command: Command, from connection: any SignalingConnection, userId: UUID, deviceId: String) {
        let key = DeviceKey(userId: userId, deviceId: deviceId)
        guard devices[key]?.connection === connection else { return }

        switch command {
        case let .invite(callee, video):
            invite(from: key, callee: callee, video: video)
        case let .accept(callId):
            accept(callId, by: key)
        case let .decline(callId):
            decline(callId, by: key)
        case let .hangup(callId):
            hangup(callId, by: key)
        case let .signal(callId, signal):
            relay(signal, callId: callId, from: key)
        }
    }

    private func invite(from key: DeviceKey, callee: CallUser, video: Bool) {
        guard let caller = devices[key] else { return }
        if let current = caller.callId {
            send(.error(code: .alreadyInCall, message: "Hang up the current call first", callId: current), to: key)
            return
        }

        let callId = UUID()
        var record = CallRecord(id: callId, callerId: key.userId, calleeId: callee.id, callerDeviceId: key.deviceId, video: video)

        // Ring every online device of the callee except the calling device itself,
        // so calling your own account rings your other devices.
        let reachable = devices.filter { $0.key.userId == callee.id && $0.key != key && $0.value.connection != nil }
        let free = Set(reachable.filter { $0.value.callId == nil }.keys)

        guard !free.isEmpty else {
            let reason: CallEndReason = reachable.isEmpty ? .unavailable : .busy
            record.finish(reason: reason)
            onRecord(record)
            send(.callEnded(callId: callId, reason: reason), to: key)
            return
        }

        let ringTimeout = configuration.ringTimeout
        var call = Call(record: record, caller: key, callee: callee, answeredBy: nil, ringing: free)
        call.ringTimer = Task { [weak self] in
            try? await Task.sleep(for: ringTimeout)
            guard !Task.isCancelled else { return }
            await self?.ringTimedOut(callId)
        }
        calls[callId] = call
        devices[key]?.callId = callId

        onRecord(record)
        send(.callRinging(callId: callId, callee: callee, devices: free.count), to: key)
        for device in free {
            send(.callIncoming(callId: callId, caller: caller.peer, video: video), to: device)
        }
        logger.info("Call ringing", metadata: ["call": "\(callId)", "devices": "\(free.count)"])
    }

    private func accept(_ callId: UUID, by key: DeviceKey) {
        guard var call = calls[callId], call.answeredBy == nil, call.ringing.contains(key) else {
            send(.error(code: .callNotFound, message: "This call is no longer ringing", callId: callId), to: key)
            return
        }
        if let current = devices[key]?.callId {
            send(.error(code: .alreadyInCall, message: "Hang up the current call first", callId: current), to: key)
            return
        }

        call.ringTimer?.cancel()
        call.ringTimer = nil
        call.answeredBy = key
        let otherDevices = call.ringing.subtracting([key])
        call.ringing = []
        call.record.status = .active
        call.record.calleeDeviceId = key.deviceId
        call.record.answeredAt = Date()
        calls[callId] = call
        devices[key]?.callId = callId

        onRecord(call.record)
        sendAccepted(call, to: call.caller, peer: key)
        sendAccepted(call, to: key, peer: call.caller)
        for device in otherDevices {
            send(.callEnded(callId: callId, reason: .answeredElsewhere), to: device)
        }
    }

    private func decline(_ callId: UUID, by key: DeviceKey) {
        guard let call = calls[callId], call.answeredBy == nil, call.ringing.contains(key) else {
            send(.error(code: .callNotFound, message: "This call is no longer ringing", callId: callId), to: key)
            return
        }
        endCall(callId, reason: .declined)
    }

    private func hangup(_ callId: UUID, by key: DeviceKey) {
        guard let call = calls[callId] else {
            send(.error(code: .callNotFound, message: "Call not found", callId: callId), to: key)
            return
        }
        if key == call.caller {
            endCall(callId, reason: call.answeredBy == nil ? .cancelled : .hangup)
        } else if key == call.answeredBy {
            endCall(callId, reason: .hangup)
        } else if call.ringing.contains(key) {
            endCall(callId, reason: .declined)
        } else {
            send(.error(code: .callNotFound, message: "Call not found", callId: callId), to: key)
        }
    }

    private func relay(_ signal: SignalPayload, callId: UUID, from key: DeviceKey) {
        guard let call = calls[callId], let target = call.otherParty(of: key) else {
            send(.error(code: .callNotFound, message: "No active call to signal", callId: callId), to: key)
            return
        }
        guard let connection = devices[target]?.connection else {
            // The other side is reconnecting and will renegotiate after `call.resumed`.
            send(.error(code: .peerUnavailable, message: "Peer is reconnecting", callId: callId), to: key)
            return
        }
        connection.send(.callSignal(callId: callId, from: key.deviceId, signal: signal))
    }

    // MARK: - Timers

    private func ringTimedOut(_ callId: UUID) {
        guard let call = calls[callId], call.answeredBy == nil else { return }
        endCall(callId, reason: .timeout)
    }

    private func startGraceTimer(for key: DeviceKey, callId: UUID) {
        guard var call = calls[callId] else { return }
        let grace = configuration.reconnectGrace
        call.graceTimers[key]?.cancel()
        call.graceTimers[key] = Task { [weak self] in
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled else { return }
            await self?.graceExpired(for: key, callId: callId)
        }
        calls[callId] = call
        if let other = call.otherParty(of: key) {
            send(.callReconnecting(callId: callId), to: other)
        }
    }

    private func graceExpired(for key: DeviceKey, callId: UUID) {
        guard calls[callId] != nil, let device = devices[key], device.connection == nil, device.callId == callId else { return }
        endCall(callId, reason: .connectionLost)
    }

    // MARK: - State Transitions

    /// Re-sends whatever a (re)connected device needs to pick up where it left off.
    private func restoreCallState(for key: DeviceKey) {
        if let callId = devices[key]?.callId, var call = calls[callId] {
            call.graceTimers.removeValue(forKey: key)?.cancel()
            calls[callId] = call
            if let other = call.otherParty(of: key) {
                // Both sides renegotiate; the caller restarts ICE on `call.resumed`.
                sendResumed(call, to: key, peer: other)
                sendResumed(call, to: other, peer: key)
            } else {
                send(.callRinging(callId: callId, callee: call.callee, devices: call.ringing.count), to: key)
            }
        }
        for call in calls.values where call.answeredBy == nil && call.ringing.contains(key) {
            guard let caller = devices[call.caller] else { continue }
            send(.callIncoming(callId: call.record.id, caller: caller.peer, video: call.record.video), to: key)
        }
    }

    private func stopRinging(_ key: DeviceKey, callId: UUID) {
        guard var call = calls[callId], call.answeredBy == nil else { return }
        call.ringing.remove(key)
        calls[callId] = call
        if call.ringing.isEmpty {
            endCall(callId, reason: .unavailable)
        } else {
            send(.callRinging(callId: callId, callee: call.callee, devices: call.ringing.count), to: call.caller)
        }
    }

    private func endCall(_ callId: UUID, reason: CallEndReason) {
        guard var call = calls.removeValue(forKey: callId) else { return }
        call.ringTimer?.cancel()
        call.graceTimers.values.forEach { $0.cancel() }
        call.record.finish(reason: reason)
        onRecord(call.record)

        var involved = call.ringing
        involved.insert(call.caller)
        if let answeredBy = call.answeredBy {
            involved.insert(answeredBy)
        }
        for key in involved {
            send(.callEnded(callId: callId, reason: reason), to: key)
            guard var device = devices[key], device.callId == callId else { continue }
            device.callId = nil
            // A device kept only to hold the call open while reconnecting can go now.
            devices[key] = device.connection == nil ? nil : device
        }
        logger.info("Call ended", metadata: ["call": "\(callId)", "reason": "\(reason.rawValue)"])
    }

    // MARK: - Sending

    private func send(_ message: ServerMessage, to key: DeviceKey) {
        devices[key]?.connection?.send(message)
    }

    private func sendAccepted(_ call: Call, to key: DeviceKey, peer: DeviceKey) {
        guard let peerDevice = devices[peer] else { return }
        send(.callAccepted(callId: call.record.id, peer: peerDevice.peer, role: call.role(of: key), video: call.record.video), to: key)
    }

    private func sendResumed(_ call: Call, to key: DeviceKey, peer: DeviceKey) {
        guard let peerDevice = devices[peer] else { return }
        send(.callResumed(callId: call.record.id, peer: peerDevice.peer, role: call.role(of: key), video: call.record.video), to: key)
    }

    private func broadcastPresence(for userId: UUID) {
        let online = devices.values.filter { $0.peer.userId == userId && $0.connection != nil }
        let peers = online.map(\.peer).sorted { $0.deviceName < $1.deviceName }
        for device in online {
            device.connection?.send(.presence(devices: peers))
        }
    }
}
