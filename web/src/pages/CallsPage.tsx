import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { ApiError } from '../api/client'
import { callsApi } from '../api/endpoints'
import type { CallHistoryItem } from '../api/types'
import { useAuth } from '../auth/AuthProvider'
import { useCalls } from '../calls/CallProvider'
import { deviceId } from '../lib/device'
import { formatDuration, formatWhen } from '../lib/format'
import {
  DesktopIcon,
  IncomingIcon,
  OutgoingIcon,
  PhoneDeviceIcon,
  PhoneIcon,
  SelfCallIcon,
  VideoIcon,
} from '../ui/icons'

const STATUS_TEXT: Record<CallHistoryItem['status'], string> = {
  completed: 'Состоялся',
  missed: 'Пропущен',
  declined: 'Отклонён',
  busy: 'Занято',
  unavailable: 'Недоступен',
  ringing: 'Звонит',
  active: 'Идёт',
}

function DialCard() {
  const { user } = useAuth()
  const { manager, state } = useCalls()
  const [email, setEmail] = useState(user?.email ?? '')
  const online = state.connection === 'online'

  const call = (video: boolean) => (event?: FormEvent) => {
    event?.preventDefault()
    const target = email.trim()
    if (target) void manager.startCall({ email: target }, video)
  }

  return (
    <section className="card">
      <h2>Новый звонок</h2>
      <form className="stack" onSubmit={call(true)}>
        <label className="field">
          <span>Email собеседника</span>
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <small className="muted">Свой email — звонок на ваши другие устройства.</small>
        </label>
        <div className="row">
          <button className="button primary grow" type="submit" disabled={!online || !email.trim()}>
            <VideoIcon /> Видео
          </button>
          <button className="button grow" type="button" onClick={call(false)} disabled={!online || !email.trim()}>
            <PhoneIcon /> Аудио
          </button>
        </div>
      </form>
    </section>
  )
}

function DevicesCard() {
  const { state } = useCalls()
  const others = state.devices.filter((device) => device.deviceId !== deviceId).length

  return (
    <section className="card">
      <h2>Мои устройства онлайн</h2>
      {state.connection !== 'online' ? (
        <p className="muted">Подключаемся к серверу звонков…</p>
      ) : (
        <ul className="list">
          {state.devices.map((device) => {
            const mobile = /iPhone|iPad|Android/.test(device.deviceName)
            return (
              <li key={device.deviceId} className="list-item">
                <span className="list-icon">{mobile ? <PhoneDeviceIcon /> : <DesktopIcon />}</span>
                <span className="grow">{device.deviceName}</span>
                {device.deviceId === deviceId && <span className="badge accent">это устройство</span>}
              </li>
            )
          })}
        </ul>
      )}
      {state.connection === 'online' && others === 0 && (
        <p className="hint">Откройте приложение на телефоне или во второй вкладке под этим же аккаунтом — и позвоните себе.</p>
      )}
    </section>
  )
}

function HistoryCard() {
  const { manager, state } = useCalls()
  const [calls, setCalls] = useState<CallHistoryItem[] | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async () => {
    try {
      setCalls((await callsApi.history(30)).calls)
      setError(null)
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : 'Не удалось загрузить историю')
    }
  }, [])

  // Reload after every finished call.
  useEffect(() => {
    void load()
  }, [load, state.endedCalls])

  const callBack = (item: CallHistoryItem, video: boolean) =>
    manager.startCall({ userId: item.peerUserId, name: item.peerUsername ?? 'Собеседник' }, video)

  return (
    <section className="card">
      <h2>Недавние</h2>
      {error && (
        <p className="form-error">
          {error}{' '}
          <button className="link-button" onClick={() => void load()}>
            Повторить
          </button>
        </p>
      )}
      {calls === null && !error && <p className="muted">Загрузка…</p>}
      {calls?.length === 0 && <p className="muted">Звонков пока не было.</p>}
      {calls && calls.length > 0 && (
        <ul className="list">
          {calls.map((item) => {
            const failed = item.status !== 'completed'
            const DirectionIcon = item.direction === 'self' ? SelfCallIcon : item.direction === 'incoming' ? IncomingIcon : OutgoingIcon
            const who = item.direction === 'self' ? 'Себе' : (item.peerUsername ?? 'Удалённый пользователь')
            return (
              <li key={item.id} className="list-item">
                <span className={`list-icon ${failed ? 'danger-text' : ''}`} title={item.direction}>
                  <DirectionIcon size={18} />
                </span>
                <span className="grow">
                  <span className={failed && item.direction !== 'outgoing' ? 'danger-text' : ''}>{who}</span>
                  <span className="muted small block">
                    {item.video ? 'Видео' : 'Аудио'} · {STATUS_TEXT[item.status]}
                    {item.duration != null && ` · ${formatDuration(item.duration)}`}
                  </span>
                </span>
                <span className="muted small">{formatWhen(item.startedAt)}</span>
                <button
                  className="icon-button"
                  onClick={() => void callBack(item, item.video)}
                  disabled={state.connection !== 'online' || state.call !== null}
                  aria-label={`Перезвонить: ${who}`}
                  title="Перезвонить"
                >
                  {item.video ? <VideoIcon size={18} /> : <PhoneIcon size={18} />}
                </button>
              </li>
            )
          })}
        </ul>
      )}
    </section>
  )
}

export function CallsPage() {
  return (
    <div className="page">
      {!window.isSecureContext && (
        <div className="banner warning">
          Камера и микрофон работают только по HTTPS или на localhost. Откройте приложение по защищённому адресу.
        </div>
      )}
      <div className="columns">
        <div className="stack">
          <DialCard />
          <DevicesCard />
        </div>
        <HistoryCard />
      </div>
    </div>
  )
}
