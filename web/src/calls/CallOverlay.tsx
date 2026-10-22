import { useCallback, useEffect, useRef, useState } from 'react'
import { isMobile } from '../lib/device'
import { formatDuration, plural } from '../lib/format'
import { CloseIcon, FlipIcon, HangUpIcon, MicIcon, MicOffIcon, PhoneIcon, VideoIcon, VideoOffIcon } from '../ui/icons'
import type { ActiveCall } from './CallManager'
import { useCalls } from './CallProvider'

function VideoView({
  stream,
  muted = false,
  className,
  onAutoplayBlocked,
}: {
  stream: MediaStream | null
  muted?: boolean
  className?: string
  onAutoplayBlocked?: () => void
}) {
  const ref = useRef<HTMLVideoElement>(null)

  useEffect(() => {
    const video = ref.current
    if (!video) return
    if (video.srcObject !== stream) video.srcObject = stream
    if (stream) video.play().catch(() => onAutoplayBlocked?.())
  }, [stream, onAutoplayBlocked])

  return <video ref={ref} className={className} autoPlay playsInline muted={muted} />
}

function statusText(call: ActiveCall, elapsed: number, hasMedia: boolean): string {
  switch (call.phase) {
    case 'dialing':
      return hasMedia ? 'Вызов…' : 'Включаем камеру…'
    case 'ringing': {
      const n = call.ringingDevices ?? 1
      return `Звонит на ${n} ${plural(n, ['устройстве', 'устройствах', 'устройствах'])}…`
    }
    case 'incoming':
      return `${call.video ? 'Видеозвонок' : 'Аудиозвонок'}${call.peerDevice ? ` · ${call.peerDevice}` : ''}`
    case 'connecting':
      return call.degraded === 'reconnecting'
        ? 'Восстанавливаем звонок…'
        : `Соединение${call.peerDevice ? ` с ${call.peerDevice}` : ''}…`
    case 'active':
      if (call.degraded === 'reconnecting') return 'Переподключение…'
      if (call.degraded === 'poor-network') return 'Плохая связь…'
      return formatDuration(elapsed)
  }
}

export function CallOverlay() {
  const { manager, state } = useCalls()
  const call = state.call
  const [elapsed, setElapsed] = useState(0)
  const [audioBlocked, setAudioBlocked] = useState(false)
  const onAutoplayBlocked = useCallback(() => setAudioBlocked(true), [])

  const connectedAt = call?.connectedAt
  useEffect(() => {
    if (!connectedAt) return
    const tick = () => setElapsed((Date.now() - connectedAt) / 1000)
    tick()
    const timer = setInterval(tick, 1000)
    return () => clearInterval(timer)
  }, [connectedAt])

  const incomingFrom = call?.phase === 'incoming' ? call.peerName : null
  useEffect(() => {
    if (!incomingFrom) return
    const original = document.title
    document.title = `📞 ${incomingFrom} звонит`
    return () => {
      document.title = original
    }
  }, [incomingFrom])

  useEffect(() => {
    if (!call) setAudioBlocked(false)
  }, [call])

  if (!call) return null

  const incoming = call.phase === 'incoming'
  const showRemoteVideo = call.video && !incoming && state.remoteStream !== null && call.phase === 'active'
  const showLocalVideo = call.video && state.localStream !== null && !state.cameraOff
  const initial = call.peerName.trim().charAt(0).toUpperCase() || '?'

  return (
    <div className={`call-screen ${showRemoteVideo ? 'has-video' : ''}`} role="dialog" aria-modal="true" aria-label="Звонок">
      {/* Always mounted: it also plays the audio of audio-only calls. */}
      <VideoView
        stream={state.remoteStream}
        className={`remote-video ${showRemoteVideo ? '' : 'invisible'}`}
        onAutoplayBlocked={onAutoplayBlocked}
      />

      {!showRemoteVideo && (
        <div className={`call-avatar ${incoming || call.phase === 'ringing' ? 'pulsing' : ''}`} aria-hidden="true">
          {initial}
        </div>
      )}

      {showLocalVideo && (
        <VideoView
          stream={state.localStream}
          muted
          className={`local-video ${state.facingMode === 'user' ? 'mirrored' : ''} ${incoming ? 'hidden' : ''}`}
        />
      )}

      <header className="call-info">
        <div className="call-name">{call.peerName}</div>
        <div className="call-status">{statusText(call, elapsed, state.localStream !== null)}</div>
      </header>

      {incoming ? (
        <div className="call-controls">
          <div className="control-with-label">
            <button className="round-button danger" onClick={() => manager.decline()} aria-label="Отклонить">
              <CloseIcon size={28} />
            </button>
            <span>Отклонить</span>
          </div>
          <div className="control-with-label">
            <button className="round-button accept" onClick={() => void manager.accept()} aria-label="Ответить">
              {call.video ? <VideoIcon size={28} /> : <PhoneIcon size={28} />}
            </button>
            <span>Ответить</span>
          </div>
        </div>
      ) : (
        <div className="call-controls">
          <button
            className={`round-button ${state.muted ? 'toggled' : ''}`}
            onClick={() => manager.toggleMute()}
            aria-label={state.muted ? 'Включить микрофон' : 'Выключить микрофон'}
            aria-pressed={state.muted}
          >
            {state.muted ? <MicOffIcon size={26} /> : <MicIcon size={26} />}
          </button>
          {call.video && (
            <button
              className={`round-button ${state.cameraOff ? 'toggled' : ''}`}
              onClick={() => manager.toggleCamera()}
              aria-label={state.cameraOff ? 'Включить камеру' : 'Выключить камеру'}
              aria-pressed={state.cameraOff}
            >
              {state.cameraOff ? <VideoOffIcon size={26} /> : <VideoIcon size={26} />}
            </button>
          )}
          {call.video && isMobile && (
            <button className="round-button" onClick={() => void manager.flipCamera()} aria-label="Сменить камеру">
              <FlipIcon size={26} />
            </button>
          )}
          <button className="round-button danger" onClick={() => manager.hangup()} aria-label="Завершить звонок">
            <HangUpIcon size={28} />
          </button>
        </div>
      )}

      {audioBlocked && (
        <button
          className="tap-to-play"
          onClick={() => {
            document.querySelectorAll<HTMLVideoElement>('.call-screen video').forEach((video) => void video.play())
            setAudioBlocked(false)
          }}
        >
          Нажмите, чтобы включить звук
        </button>
      )}
    </div>
  )
}
