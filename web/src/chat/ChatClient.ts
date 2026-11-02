import { api } from '../api/client'
import type { ChatClientMessage, ChatHistoryResponse, ChatMessage, ChatServerMessage, ChatUser } from './protocol'

// The web counterpart of the iOS client in the guide (/guide): same protocol, same
// rules. It also keeps a log of raw frames so you can see what goes over the wire.

const PING_INTERVAL_MS = 20_000
const MAX_BACKOFF_MS = 30_000
/** Repeat `typing: true` this often while the user keeps typing. */
const TYPING_REPEAT_MS = 3_000
/** Hide someone's "typing" if no repeat arrives within this time. */
const TYPING_TTL_MS = 6_000
const MAX_FRAMES = 200

export type ChatConnection = 'offline' | 'connecting' | 'online'

export interface PendingMessage {
  clientId: string
  text: string
  failed: boolean
}

export interface Frame {
  id: number
  direction: 'in' | 'out' | 'info'
  text: string
  at: number
}

export interface ChatState {
  connection: ChatConnection
  me: ChatUser | null
  messages: ChatMessage[]
  pending: PendingMessage[]
  online: ChatUser[]
  typing: ChatUser[]
  hasOlder: boolean
  loadingOlder: boolean
  error: string | null
  frames: Frame[]
}

const initialState: ChatState = {
  connection: 'offline',
  me: null,
  messages: [],
  pending: [],
  online: [],
  typing: [],
  hasOlder: false,
  loadingOlder: false,
  error: null,
  frames: [],
}

/** Adds messages without duplicates, in `seq` order. */
export function mergeMessages(current: ChatMessage[], incoming: ChatMessage[]): ChatMessage[] {
  const bySeq = new Map(current.map((message) => [message.seq, message]))
  for (const message of incoming) bySeq.set(message.seq, message)
  return [...bySeq.values()].sort((a, b) => a.seq - b.seq)
}

export class ChatClient {
  private ws: WebSocket | null = null
  private running = false
  /** Bumped on every connect and on stop(): callbacks of older sockets are ignored. */
  private generation = 0
  private connecting = false
  private attempt = 0
  private gotWelcome = false
  /** The last socket closed before `welcome`: the token may have been rejected. */
  private tokenSuspect = false
  private awaitingPong = false
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private pingTimer: ReturnType<typeof setInterval> | undefined
  private typingTimer: ReturnType<typeof setInterval> | undefined
  private typingSentAt: number | null = null
  private typingUntil = new Map<string, number>()
  private typists = new Map<string, ChatUser>()
  private frameId = 0
  private state: ChatState = initialState
  private listeners = new Set<() => void>()

  constructor(
    readonly room: string,
    /** Returns an access token; `force` asks for a refreshed one. */
    private readonly getToken: (force: boolean) => Promise<string>,
  ) {}

  // ---------- Store for useSyncExternalStore ----------

  subscribe = (listener: () => void) => {
    this.listeners.add(listener)
    return () => this.listeners.delete(listener)
  }

  getState = () => this.state

  private update(patch: Partial<ChatState>) {
    this.state = { ...this.state, ...patch }
    this.listeners.forEach((listener) => listener())
  }

  private log(direction: Frame['direction'], text: string) {
    const frames = [...this.state.frames, { id: ++this.frameId, direction, text, at: Date.now() }]
    this.update({ frames: frames.slice(-MAX_FRAMES) })
  }

  clearFrames() {
    this.update({ frames: [] })
  }

  // ---------- Lifecycle ----------

  start() {
    if (this.running) return
    this.running = true
    window.addEventListener('online', this.wake)
    document.addEventListener('visibilitychange', this.wake)
    void this.connect()
  }

  stop() {
    this.running = false
    this.generation += 1
    this.connecting = false
    window.removeEventListener('online', this.wake)
    document.removeEventListener('visibilitychange', this.wake)
    clearTimeout(this.reconnectTimer)
    clearInterval(this.pingTimer)
    clearInterval(this.typingTimer)
    this.detach(1000)
    this.update({ connection: 'offline' })
  }

  /** Network back or tab visible again: connect now instead of waiting out the backoff. */
  private wake = () => {
    if (!this.running || this.ws || this.connecting || document.hidden) return
    clearTimeout(this.reconnectTimer)
    this.attempt = 0
    void this.connect()
  }

  // ---------- Actions ----------

  send(raw: string) {
    const text = raw.trim()
    if (!text) return
    const item: PendingMessage = { clientId: crypto.randomUUID(), text, failed: false }
    this.update({ pending: [...this.state.pending, item] })
    this.typingSentAt = null
    // Offline, the message waits in `pending` and goes out after the next welcome.
    if (this.state.connection === 'online') this.transmit({ type: 'send', clientId: item.clientId, text })
  }

  retry(clientId: string) {
    const item = this.state.pending.find((pending) => pending.clientId === clientId)
    if (!item) return
    this.update({ pending: this.state.pending.map((p) => (p === item ? { ...p, failed: false } : p)) })
    if (this.state.connection === 'online') this.transmit({ type: 'send', clientId, text: item.text })
  }

  /** Call on every change of the input. */
  draftChanged(draft: string) {
    if (this.state.connection !== 'online') return
    const now = Date.now()
    if (!draft.trim()) {
      if (this.typingSentAt !== null) this.transmit({ type: 'typing', isTyping: false })
      this.typingSentAt = null
    } else if (this.typingSentAt === null || now - this.typingSentAt > TYPING_REPEAT_MS) {
      this.typingSentAt = now
      this.transmit({ type: 'typing', isTyping: true })
    }
  }

  /** History above the first loaded message comes over REST, not the socket. */
  async loadOlder() {
    const first = this.state.messages[0]
    if (!first || this.state.loadingOlder) return
    this.update({ loadingOlder: true })
    try {
      const page = await api<ChatHistoryResponse>(`/chat/rooms/${this.room}/messages?before=${first.seq}`)
      this.update({ messages: mergeMessages(this.state.messages, page.messages), hasOlder: page.hasMore })
    } catch {
      this.update({ error: 'Не удалось загрузить историю' })
    } finally {
      this.update({ loadingOlder: false })
    }
  }

  // ---------- Socket ----------

  private async connect() {
    if (!this.running || this.ws || this.connecting) return
    this.connecting = true
    const generation = ++this.generation
    this.update({ connection: 'connecting' })

    let token: string
    try {
      // A browser cannot see the HTTP status of a failed handshake, so a socket that
      // closed before `welcome` is the hint that the token needs refreshing.
      token = await this.getToken(this.tokenSuspect)
    } catch {
      if (generation !== this.generation) return
      this.connecting = false
      this.scheduleReconnect()
      return
    }
    if (generation !== this.generation || !this.running) return
    this.connecting = false

    const params = new URLSearchParams({ room: this.room })
    const lastSeq = this.state.messages.at(-1)?.seq
    // Reconnecting: ask only for what we missed.
    if (lastSeq !== undefined) params.set('after', String(lastSeq))
    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    const url = `${scheme}://${location.host}/api/v1/chat/ws?${params}`
    this.log('info', `подключение: ${url}&token=…`)

    params.set('token', token)
    const ws = new WebSocket(`${scheme}://${location.host}/api/v1/chat/ws?${params}`)
    this.ws = ws
    this.gotWelcome = false
    const resuming = lastSeq !== undefined

    ws.onmessage = (event) => {
      if (generation !== this.generation) return
      const text = String(event.data)
      this.log('in', text)
      let message: ChatServerMessage
      try {
        message = JSON.parse(text) as ChatServerMessage
      } catch {
        return
      }
      this.handle(message, resuming)
    }

    ws.onclose = (event) => {
      if (generation !== this.generation) return
      this.log('info', `закрыто: код ${event.code}${event.reason ? `, ${event.reason}` : ''}`)
      this.closed()
    }
  }

  /** Forgets the current socket without waiting for its close event. */
  private detach(code?: number) {
    const ws = this.ws
    if (!ws) return
    ws.onmessage = null
    ws.onclose = null
    if (code !== undefined) ws.close(code)
    this.ws = null
  }

  private closed() {
    this.tokenSuspect = !this.gotWelcome
    this.gotWelcome = false
    this.ws = null
    clearInterval(this.pingTimer)
    this.update({ connection: 'offline' })
    this.scheduleReconnect()
  }

  private scheduleReconnect() {
    if (!this.running) return
    // 0.5, 1, 2, 4 … up to 30 s, plus jitter so many clients do not reconnect in step.
    const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempt) + Math.random() * 500
    this.attempt += 1
    this.log('info', `переподключение через ${(delay / 1000).toFixed(1)} с`)
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = setTimeout(() => void this.connect(), delay)
  }

  private transmit(message: ChatClientMessage) {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN) return
    const text = JSON.stringify(message)
    this.ws.send(text)
    this.log('out', text)
  }

  /**
   * Browsers cannot send WebSocket ping frames, so the app pings with a JSON frame.
   * No pong by the next ping means the connection is dead even if no error came.
   */
  private startPinging() {
    clearInterval(this.pingTimer)
    this.awaitingPong = false
    this.pingTimer = setInterval(() => {
      if (this.awaitingPong) {
        this.log('info', 'нет pong: соединение мёртвое, переподключаемся')
        this.detach(4000)
        this.closed()
        return
      }
      this.awaitingPong = true
      this.transmit({ type: 'ping' })
    }, PING_INTERVAL_MS)
  }

  // ---------- Incoming ----------

  private handle(message: ChatServerMessage, resuming: boolean) {
    switch (message.type) {
      case 'welcome': {
        this.gotWelcome = true
        this.tokenSuspect = false
        this.attempt = 0
        const gap = resuming && message.hasMore
        this.update({
          connection: 'online',
          me: message.you,
          online: message.online,
          // Missed more than the server sent back: there is a hole, start over from here.
          messages: gap ? message.messages : mergeMessages(this.state.messages, message.messages),
          hasOlder: resuming && !gap ? this.state.hasOlder : message.hasMore,
          error: null,
        })
        // Resend everything unconfirmed: the same clientId is never stored twice.
        for (const item of this.state.pending) {
          if (!item.failed) this.transmit({ type: 'send', clientId: item.clientId, text: item.text })
        }
        this.startPinging()
        break
      }
      case 'message':
        this.typingUntil.delete(message.message.author.id)
        this.update({
          messages: mergeMessages(this.state.messages, [message.message]),
          pending: this.state.pending.filter((p) => p.clientId !== message.message.clientId),
        })
        this.refreshTyping()
        break
      case 'presence':
        this.update({ online: message.online })
        break
      case 'typing':
        if (message.isTyping) {
          this.typists.set(message.user.id, message.user)
          this.typingUntil.set(message.user.id, Date.now() + TYPING_TTL_MS)
        } else {
          this.typingUntil.delete(message.user.id)
        }
        this.refreshTyping()
        break
      case 'error':
        this.update({
          error: message.message,
          pending: message.clientId
            ? this.state.pending.map((p) => (p.clientId === message.clientId ? { ...p, failed: true } : p))
            : this.state.pending,
        })
        break
      case 'pong':
        this.awaitingPong = false
        break
    }
  }

  private refreshTyping() {
    const now = Date.now()
    for (const [id, until] of this.typingUntil) {
      if (until <= now) this.typingUntil.delete(id)
    }
    const typing = [...this.typingUntil.keys()].flatMap((id) => this.typists.get(id) ?? [])
    if (typing.length !== this.state.typing.length || typing.some((user, i) => user.id !== this.state.typing[i]?.id)) {
      this.update({ typing })
    }
    clearInterval(this.typingTimer)
    if (this.typingUntil.size > 0) this.typingTimer = setInterval(() => this.refreshTyping(), 1000)
  }
}
