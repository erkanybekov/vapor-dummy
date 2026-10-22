import type { CallEndReason } from '../api/types'
import { END_REASON_TEXT, ERROR_TEXT, type CallPeer, type CallRole, type ServerMessage, type SignalPayload } from './protocol'
import { startRinging, stopRinging } from './ringtone'
import { SignalingClient, type ConnectionState } from './SignalingClient'

// Everything about calls that is not rendering: the signaling socket, the
// WebRTC peer connection, camera/microphone, and the call state machine.
// React reads it through `subscribe`/`getSnapshot` (useSyncExternalStore).
//
// Negotiation: the server tells each side its role; the caller creates the SDP
// offer, the callee answers, and both trickle ICE candidates. Media then flows
// directly between the devices (or through TURN), never through Vapor.

export type CallPhase = 'dialing' | 'ringing' | 'incoming' | 'connecting' | 'active'

export interface ActiveCall {
  /** null until the server acknowledges our invite. */
  id: string | null
  role: CallRole
  phase: CallPhase
  video: boolean
  peerName: string
  peerDevice?: string
  ringingDevices?: number
  connectedAt?: number
  /** Trouble while the call is up: the peer's signaling dropped, or the media path is struggling. */
  degraded?: 'reconnecting' | 'poor-network'
}

export interface CallSnapshot {
  connection: ConnectionState
  /** Online devices of my own account, this one included. */
  devices: CallPeer[]
  call: ActiveCall | null
  localStream: MediaStream | null
  remoteStream: MediaStream | null
  muted: boolean
  cameraOff: boolean
  facingMode: 'user' | 'environment'
  /** Incremented whenever a call ends, so history views know to reload. */
  endedCalls: number
}

export type CallTarget = { email: string } | { userId: string; name: string }

interface Options {
  deviceId: string
  deviceName: string
  getToken: (force: boolean) => Promise<string>
  onNotice: (text: string) => void
}

class CallCancelled extends Error {}

const DEFAULT_ICE_SERVERS: RTCIceServer[] = [{ urls: ['stun:stun.l.google.com:19302'] }]

export function mediaErrorText(error: unknown): string {
  const name = error instanceof DOMException ? error.name : ''
  if (name === 'NotAllowedError') return 'Нет доступа к камере или микрофону: разрешите его в настройках браузера'
  if (name === 'NotFoundError') return 'Камера или микрофон не найдены'
  if (name === 'NotReadableError') return 'Камера занята другим приложением'
  if (!window.isSecureContext) return 'Камера работает только по HTTPS'
  return 'Не удалось включить камеру или микрофон'
}

export class CallManager {
  private snapshot: CallSnapshot = {
    connection: 'offline',
    devices: [],
    call: null,
    localStream: null,
    remoteStream: null,
    muted: false,
    cameraOff: false,
    facingMode: 'user',
    endedCalls: 0,
  }
  private readonly listeners = new Set<() => void>()
  private readonly signaling: SignalingClient
  private iceServers: RTCIceServer[] = DEFAULT_ICE_SERVERS
  private pc: RTCPeerConnection | null = null
  private pendingCandidates: RTCIceCandidateInit[] = []
  /** Negotiation steps run strictly one after another. */
  private queue: Promise<void> = Promise.resolve()
  private inviteSent = false
  /** We hung up before the server told us the call id: hang up as soon as it does. */
  private cancelPendingInvite = false

  constructor(private readonly options: Options) {
    this.signaling = new SignalingClient({
      deviceId: options.deviceId,
      deviceName: options.deviceName,
      getToken: options.getToken,
      onMessage: (message) => this.handle(message),
      onState: (connection) => this.update({ connection }),
    })
  }

  // MARK: - Store

  subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getSnapshot = (): CallSnapshot => this.snapshot

  private update(patch: Partial<CallSnapshot>) {
    this.snapshot = { ...this.snapshot, ...patch }
    this.listeners.forEach((listener) => listener())
  }

  private updateCall(patch: Partial<ActiveCall>) {
    if (this.snapshot.call) this.update({ call: { ...this.snapshot.call, ...patch } })
  }

  // MARK: - Lifecycle

  start() {
    this.signaling.start()
  }

  stop() {
    this.endLocally()
    this.signaling.stop()
  }

  /** Take the connection back after another tab of this device replaced it. */
  reconnect() {
    this.signaling.start()
  }

  // MARK: - User actions

  async startCall(target: CallTarget, video: boolean) {
    if (this.snapshot.call) return
    if (this.snapshot.connection !== 'online') {
      this.options.onNotice('Нет связи с сервером звонков')
      return
    }
    const peerName = 'email' in target ? target.email : target.name
    this.update({ call: { id: null, role: 'caller', phase: 'dialing', video, peerName } })

    try {
      await this.getMedia(video)
    } catch (error) {
      if (!(error instanceof CallCancelled)) {
        this.options.onNotice(mediaErrorText(error))
        this.endLocally()
      }
      return
    }

    const invite = 'email' in target ? { calleeEmail: target.email } : { calleeId: target.userId }
    if (!this.signaling.send({ type: 'call.invite', video, ...invite })) {
      this.options.onNotice('Нет связи с сервером звонков')
      this.endLocally()
      return
    }
    this.inviteSent = true
  }

  async accept() {
    const call = this.snapshot.call
    if (!call?.id || call.phase !== 'incoming') return
    const callId = call.id
    stopRinging()
    this.updateCall({ phase: 'connecting' })

    try {
      await this.getMedia(call.video)
    } catch (error) {
      if (error instanceof CallCancelled) return
      this.options.onNotice(mediaErrorText(error))
      this.signaling.send({ type: 'call.decline', callId })
      this.endLocally()
      return
    }
    // Ready before the caller's offer can arrive.
    this.createPeerConnection()
    this.signaling.send({ type: 'call.accept', callId })
  }

  decline() {
    const call = this.snapshot.call
    if (call?.id) this.signaling.send({ type: 'call.decline', callId: call.id })
    this.endLocally()
  }

  hangup() {
    const call = this.snapshot.call
    if (!call) return
    if (call.id) {
      this.signaling.send({ type: call.phase === 'incoming' ? 'call.decline' : 'call.hangup', callId: call.id })
    } else if (this.inviteSent) {
      this.cancelPendingInvite = true
    }
    this.endLocally()
  }

  toggleMute() {
    const tracks = this.snapshot.localStream?.getAudioTracks() ?? []
    const muted = !this.snapshot.muted
    tracks.forEach((track) => (track.enabled = !muted))
    this.update({ muted })
  }

  toggleCamera() {
    const tracks = this.snapshot.localStream?.getVideoTracks() ?? []
    const cameraOff = !this.snapshot.cameraOff
    tracks.forEach((track) => (track.enabled = !cameraOff))
    this.update({ cameraOff })
  }

  async flipCamera() {
    const stream = this.snapshot.localStream
    const [oldTrack] = stream?.getVideoTracks() ?? []
    if (!stream || !oldTrack) return
    const facingMode = this.snapshot.facingMode === 'user' ? 'environment' : 'user'
    try {
      const fresh = await navigator.mediaDevices.getUserMedia({ video: { facingMode } })
      const [newTrack] = fresh.getVideoTracks()
      if (!newTrack) return
      newTrack.enabled = !this.snapshot.cameraOff
      const sender = this.pc?.getSenders().find((s) => s.track?.kind === 'video')
      await sender?.replaceTrack(newTrack)
      oldTrack.stop()
      const next = new MediaStream([...stream.getAudioTracks(), newTrack])
      this.update({ localStream: next, facingMode })
    } catch {
      this.options.onNotice('Не удалось переключить камеру')
    }
  }

  // MARK: - Server messages

  private handle(message: ServerMessage) {
    const call = this.snapshot.call

    switch (message.type) {
      case 'hello':
        this.iceServers = message.iceServers.length ? message.iceServers : DEFAULT_ICE_SERVERS
        break

      case 'presence':
        this.update({ devices: message.devices })
        break

      case 'call.ringing':
        if (this.cancelPendingInvite) {
          this.cancelPendingInvite = false
          this.signaling.send({ type: 'call.hangup', callId: message.callId })
          return
        }
        if (!call || call.role !== 'caller' || (call.id && call.id !== message.callId)) return
        this.updateCall({
          id: message.callId,
          phase: call.phase === 'dialing' || call.phase === 'ringing' ? 'ringing' : call.phase,
          peerName: message.callee.username,
          ringingDevices: message.devices,
        })
        break

      case 'call.incoming':
        if (call) return // busy here; the account's other devices keep ringing
        this.update({
          call: {
            id: message.callId,
            role: 'callee',
            phase: 'incoming',
            video: message.video,
            peerName: message.caller.username,
            peerDevice: message.caller.deviceName,
          },
        })
        startRinging()
        break

      case 'call.accepted':
        if (!call || call.id !== message.callId) return
        this.updateCall({ phase: 'connecting', peerName: message.peer.username, peerDevice: message.peer.deviceName })
        if (message.role === 'caller') this.enqueue(() => this.negotiate())
        break

      case 'call.resumed':
        this.enqueue(() => this.resume(message))
        break

      case 'call.reconnecting':
        if (call?.id === message.callId) this.updateCall({ degraded: 'reconnecting' })
        break

      case 'call.signal':
        if (call?.id === message.callId) this.enqueue(() => this.applySignal(message.signal))
        break

      case 'call.ended':
        if (!call) {
          this.cancelPendingInvite = false
          return
        }
        if (call.id ? call.id !== message.callId : call.role !== 'caller') return
        this.notifyEnded(message.reason)
        this.endLocally()
        break

      case 'error':
        if (message.code === 'peer_unavailable') return // the peer is reconnecting
        this.options.onNotice(ERROR_TEXT[message.code] ?? message.message)
        if (call && !call.id && call.role === 'caller') this.endLocally()
        if (!call) this.cancelPendingInvite = false
        break

      case 'pong':
        break
    }
  }

  private notifyEnded(reason: CallEndReason) {
    // A plain hang-up is obvious from the screen closing; everything else is worth saying.
    if (reason !== 'hangup') this.options.onNotice(END_REASON_TEXT[reason] ?? reason)
  }

  private enqueue(step: () => Promise<void>) {
    this.queue = this.queue.then(step).catch((error: unknown) => console.warn('[calls] negotiation step failed', error))
  }

  // MARK: - WebRTC

  private async getMedia(video: boolean): Promise<MediaStream> {
    if (this.snapshot.localStream) return this.snapshot.localStream
    if (!navigator.mediaDevices?.getUserMedia) throw new Error('getUserMedia unavailable')

    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true },
      video: video ? { facingMode: this.snapshot.facingMode, width: { ideal: 1280 }, height: { ideal: 720 } } : false,
    })
    // The call may have ended while the browser was asking for permission.
    if (!this.snapshot.call) {
      stream.getTracks().forEach((track) => track.stop())
      throw new CallCancelled()
    }
    this.update({ localStream: stream, muted: false, cameraOff: false })
    return stream
  }

  private createPeerConnection(): RTCPeerConnection {
    if (this.pc) return this.pc
    const pc = new RTCPeerConnection({ iceServers: this.iceServers })
    this.pc = pc
    this.pendingCandidates = []
    const stream = this.snapshot.localStream
    stream?.getTracks().forEach((track) => pc.addTrack(track, stream))

    pc.onicecandidate = ({ candidate }) => {
      const callId = this.snapshot.call?.id
      if (!candidate || !callId) return
      this.signaling.send({ type: 'call.signal', callId, signal: { kind: 'candidate', candidate: candidate.toJSON() } })
    }

    pc.ontrack = (event) => {
      this.update({ remoteStream: event.streams[0] ?? new MediaStream([event.track]) })
    }

    pc.onconnectionstatechange = () => {
      const call = this.snapshot.call
      if (pc !== this.pc || !call) return
      switch (pc.connectionState) {
        case 'connected':
          this.updateCall({ phase: 'active', connectedAt: call.connectedAt ?? Date.now(), degraded: undefined })
          break
        case 'disconnected':
          this.updateCall({ degraded: 'poor-network' })
          break
        case 'failed':
          this.updateCall({ degraded: 'reconnecting' })
          // The caller drives renegotiation: restart ICE on the same connection.
          if (call.role === 'caller') this.enqueue(() => this.negotiate({ iceRestart: true }))
          break
        default:
          break
      }
    }
    return pc
  }

  private async negotiate(options?: RTCOfferOptions) {
    const callId = this.snapshot.call?.id
    if (!callId) return
    const pc = this.createPeerConnection()
    await pc.setLocalDescription(await pc.createOffer(options))
    this.signaling.send({ type: 'call.signal', callId, signal: { kind: 'offer', sdp: pc.localDescription?.sdp } })
  }

  private async applySignal(signal: SignalPayload) {
    const callId = this.snapshot.call?.id
    if (!callId || !this.snapshot.localStream) return
    const pc = this.createPeerConnection()

    if (signal.kind === 'offer') {
      await pc.setRemoteDescription({ type: 'offer', sdp: signal.sdp })
      await this.flushCandidates(pc)
      await pc.setLocalDescription(await pc.createAnswer())
      this.signaling.send({ type: 'call.signal', callId, signal: { kind: 'answer', sdp: pc.localDescription?.sdp } })
    } else if (signal.kind === 'answer') {
      await pc.setRemoteDescription({ type: 'answer', sdp: signal.sdp })
      await this.flushCandidates(pc)
    } else if (signal.candidate) {
      // Candidates can arrive before the remote description; hold them until then.
      if (pc.remoteDescription) await pc.addIceCandidate(signal.candidate).catch(() => undefined)
      else this.pendingCandidates.push(signal.candidate)
    }
  }

  private async flushCandidates(pc: RTCPeerConnection) {
    for (const candidate of this.pendingCandidates.splice(0)) {
      await pc.addIceCandidate(candidate).catch(() => undefined)
    }
  }

  /**
   * After a signaling reconnect (or a page reload mid-call) both sides start a
   * fresh peer connection and the caller sends a new offer.
   */
  private async resume(message: Extract<ServerMessage, { type: 'call.resumed' }>) {
    const call = this.snapshot.call
    if (call && call.id !== message.callId) return
    const details = {
      id: message.callId,
      role: message.role,
      video: message.video,
      phase: 'connecting' as const,
      peerName: message.peer.username,
      peerDevice: message.peer.deviceName,
      degraded: undefined,
    }
    this.update({ call: call ? { ...call, ...details } : details })

    try {
      await this.getMedia(message.video)
    } catch (error) {
      if (!(error instanceof CallCancelled)) this.options.onNotice(mediaErrorText(error))
      return
    }
    this.closePeerConnection()
    this.createPeerConnection()
    if (message.role === 'caller') await this.negotiate()
  }

  private closePeerConnection() {
    if (!this.pc) return
    this.pc.onicecandidate = null
    this.pc.ontrack = null
    this.pc.onconnectionstatechange = null
    this.pc.close()
    this.pc = null
    this.pendingCandidates = []
  }

  private endLocally() {
    const hadCall = this.snapshot.call !== null
    stopRinging()
    this.closePeerConnection()
    this.snapshot.localStream?.getTracks().forEach((track) => track.stop())
    this.inviteSent = false
    this.update({
      call: null,
      localStream: null,
      remoteStream: null,
      muted: false,
      cameraOff: false,
      endedCalls: this.snapshot.endedCalls + (hadCall ? 1 : 0),
    })
  }
}
