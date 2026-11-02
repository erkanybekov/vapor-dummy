import { useEffect, useLayoutEffect, useMemo, useRef, useState, useSyncExternalStore, type FormEvent, type KeyboardEvent } from 'react'
import { Link } from 'react-router'
import { getAccessToken, refreshSession } from '../api/client'
import { ChatClient, type ChatConnection, type Frame } from '../chat/ChatClient'
import { MAX_MESSAGE_LENGTH } from '../chat/protocol'
import { formatWhen, plural } from '../lib/format'
import { SendIcon } from '../ui/icons'

const ROOM_KEY = 'vapor.chat.room'
const ROOM_PATTERN = /^[a-z0-9-]{1,32}$/

const CONNECTION_TEXT: Record<ChatConnection, string> = {
  online: 'онлайн',
  connecting: 'подключение…',
  offline: 'нет связи',
}

function readRoom(): string {
  try {
    const stored = localStorage.getItem(ROOM_KEY)
    if (stored && ROOM_PATTERN.test(stored)) return stored
  } catch {
    // Storage can be unavailable; the default room is fine.
  }
  return 'general'
}

function RoomPicker({ room, onChange }: { room: string; onChange: (room: string) => void }) {
  const [draft, setDraft] = useState(room)
  const valid = ROOM_PATTERN.test(draft)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (valid && draft !== room) onChange(draft)
  }

  return (
    <form className="row room-picker" onSubmit={submit}>
      <input
        aria-label="Комната"
        value={draft}
        onChange={(event) => setDraft(event.target.value.toLowerCase())}
        maxLength={32}
        spellCheck={false}
      />
      <button className="button" type="submit" disabled={!valid || draft === room}>
        Перейти
      </button>
    </form>
  )
}

function FrameLog({ frames, onClear }: { frames: Frame[]; onClear: () => void }) {
  const log = useRef<HTMLDivElement>(null)
  // Scroll the log itself; scrollIntoView would drag the whole page along.
  useEffect(() => {
    if (log.current) log.current.scrollTop = log.current.scrollHeight
  }, [frames])

  const arrow: Record<Frame['direction'], string> = { in: '←', out: '→', info: '·' }
  return (
    <section className="card">
      <div className="card-title-row">
        <h2>Кадры WebSocket</h2>
        <button className="link-button" onClick={onClear}>
          Очистить
        </button>
      </div>
      <p className="muted small">← от сервера, → от тебя. Ровно это увидит и твой iOS-клиент.</p>
      <div className="frame-log" role="log" aria-live="off" ref={log}>
        {frames.length === 0 && <p className="muted">Пока пусто.</p>}
        {frames.map((frame) => (
          <div key={frame.id} className={`frame ${frame.direction}`}>
            <span className="frame-arrow">{arrow[frame.direction]}</span>
            <code>{frame.text}</code>
          </div>
        ))}
      </div>
    </section>
  )
}

export function ChatPage() {
  const [room, setRoom] = useState(readRoom)
  const client = useMemo(
    () => new ChatClient(room, async (force) => (force ? (await refreshSession()).accessToken : getAccessToken())),
    [room],
  )
  const state = useSyncExternalStore(client.subscribe, client.getState)
  const [draft, setDraft] = useState('')
  const listRef = useRef<HTMLDivElement>(null)
  const stickToBottom = useRef(true)

  useEffect(() => {
    client.start()
    return () => client.stop()
  }, [client])

  // Follow new messages, unless the user scrolled up to read.
  useLayoutEffect(() => {
    const list = listRef.current
    if (list && stickToBottom.current) list.scrollTop = list.scrollHeight
  }, [state.messages, state.pending])

  const changeRoom = (next: string) => {
    try {
      localStorage.setItem(ROOM_KEY, next)
    } catch {
      // Not remembered; still switch.
    }
    setRoom(next)
  }

  const submit = (event?: FormEvent) => {
    event?.preventDefault()
    if (!draft.trim()) return
    client.send(draft)
    setDraft('')
    stickToBottom.current = true
  }

  const onKeyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.key === 'Enter' && !event.shiftKey && !event.nativeEvent.isComposing) {
      event.preventDefault()
      submit()
    }
  }

  const typingText =
    state.typing.length === 0
      ? ''
      : `${state.typing.map((user) => user.username).join(', ')} ${state.typing.length === 1 ? 'печатает' : 'печатают'}…`

  const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
  const endpoint = `${scheme}://${location.host}/api/v1/chat/ws?room=${room}`

  return (
    <div className="page">
      <div className="page-header">
        <h1>Учебный чат</h1>
        <div className="row">
          <span className={`badge ${state.connection === 'online' ? 'accent' : ''}`}>
            <span className={`status-dot inline ${state.connection}`} aria-hidden="true" /> #{room} · {CONNECTION_TEXT[state.connection]}
          </span>
        </div>
      </div>

      {state.error && <div className="banner error">{state.error}</div>}

      <div className="columns chat-columns">
        <section className="card chat-card">
          <div className="chat-messages" ref={listRef} onScroll={(event) => {
            const list = event.currentTarget
            stickToBottom.current = list.scrollHeight - list.scrollTop - list.clientHeight < 40
          }}>
            {state.hasOlder && (
              <button className="link-button older" onClick={() => void client.loadOlder()} disabled={state.loadingOlder}>
                {state.loadingOlder ? 'Загрузка…' : 'Показать более ранние'}
              </button>
            )}
            {state.messages.length === 0 && state.pending.length === 0 && (
              <p className="muted empty">В #{room} пока тихо. Напиши первым — или подключись с телефона.</p>
            )}
            {state.messages.map((message) => {
              const mine = message.author.id === state.me?.id
              return (
                <div key={message.seq} className={`bubble ${mine ? 'mine' : ''}`}>
                  {!mine && <span className="bubble-author">{message.author.username}</span>}
                  <span className="bubble-text">{message.text}</span>
                  <span className="bubble-meta" title={`seq ${message.seq}`}>
                    {formatWhen(message.sentAt)}
                  </span>
                </div>
              )
            })}
            {state.pending.map((item) => (
              <div key={item.clientId} className={`bubble mine pending ${item.failed ? 'failed' : ''}`}>
                <span className="bubble-text">{item.text}</span>
                <span className="bubble-meta">
                  {item.failed ? (
                    <>
                      не отправлено ·{' '}
                      <button className="link-button" onClick={() => client.retry(item.clientId)}>
                        повторить
                      </button>
                    </>
                  ) : state.connection === 'online' ? (
                    'отправляется…'
                  ) : (
                    'ждёт связи'
                  )}
                </span>
              </div>
            ))}
          </div>
          <p className="typing-line muted small" aria-live="polite">
            {typingText}
          </p>
          <form className="composer" onSubmit={submit}>
            <textarea
              aria-label="Сообщение"
              placeholder="Сообщение"
              rows={1}
              maxLength={MAX_MESSAGE_LENGTH}
              value={draft}
              onChange={(event) => {
                setDraft(event.target.value)
                client.draftChanged(event.target.value)
              }}
              onKeyDown={onKeyDown}
            />
            <button className="button primary" type="submit" disabled={!draft.trim()} aria-label="Отправить">
              <SendIcon size={18} />
            </button>
          </form>
        </section>

        <div className="stack">
          <section className="card">
            <h2>Комната</h2>
            <RoomPicker room={room} onChange={changeRoom} />
            <p className="muted small">Латиница в нижнем регистре, цифры и дефис.</p>
          </section>

          <section className="card">
            <h2>
              Онлайн · {state.online.length} {plural(state.online.length, ['человек', 'человека', 'человек'])}
            </h2>
            <ul className="list">
              {state.online.map((user) => (
                <li key={user.id} className="list-item">
                  <span className="status-dot inline online" aria-hidden="true" />
                  <span className="grow">{user.username}</span>
                  {user.id === state.me?.id && <span className="badge accent">это ты</span>}
                </li>
              ))}
            </ul>
          </section>

          <section className="card">
            <h2>Подключиться с iOS</h2>
            <code className="endpoint">{endpoint}</code>
            <p className="muted small">
              Заголовок <code>Authorization: Bearer &lt;accessToken&gt;</code>. Пошагово — в{' '}
              <Link to="/guide">гайде</Link>.
            </p>
          </section>

          <FrameLog frames={state.frames} onClear={() => client.clearFrames()} />
        </div>
      </div>
    </div>
  )
}
