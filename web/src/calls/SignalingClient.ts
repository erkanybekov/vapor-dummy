import type { ClientMessage, ServerMessage } from './protocol'

export type ConnectionState = 'offline' | 'connecting' | 'online' | 'replaced'

/** Close code the server uses when a newer socket from this device took over. */
const REPLACED_CLOSE_CODE = 4000
const PING_INTERVAL_MS = 20_000
const MAX_BACKOFF_MS = 10_000

interface Options {
  deviceId: string
  deviceName: string
  /** Returns a fresh access token; `force` asks for a refresh even if it looks valid. */
  getToken: (force: boolean) => Promise<string>
  onMessage: (message: ServerMessage) => void
  onState: (state: ConnectionState) => void
}

/**
 * Keeps one signaling WebSocket alive: reconnects with exponential backoff,
 * reconnects immediately when the network or the tab comes back, and sends an
 * app-level ping so proxies do not drop an idle socket.
 */
export class SignalingClient {
  private ws: WebSocket | null = null
  private running = false
  /** Bumped by stop(): an in-flight connect() from before must not open a socket. */
  private generation = 0
  private connecting = false
  private attempt = 0
  private gotHello = false
  private reconnectTimer: ReturnType<typeof setTimeout> | undefined
  private pingTimer: ReturnType<typeof setInterval> | undefined

  constructor(private readonly options: Options) {}

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
    if (this.ws) {
      this.ws.onclose = null
      this.ws.close(1000)
      this.ws = null
    }
    this.options.onState('offline')
  }

  /** Sends a message if the socket is open; returns whether it went out. */
  send(message: ClientMessage): boolean {
    if (!this.ws || this.ws.readyState !== WebSocket.OPEN || !this.gotHello) return false
    this.ws.send(JSON.stringify(message))
    return true
  }

  private wake = () => {
    if (!this.running || this.ws || document.hidden) return
    clearTimeout(this.reconnectTimer)
    this.attempt = 0
    void this.connect()
  }

  private async connect() {
    if (!this.running || this.ws || this.connecting) return
    const generation = this.generation
    this.connecting = true
    this.options.onState('connecting')

    let token: string
    try {
      // If the last socket closed before the server said hello, the token may have
      // been rejected (the browser cannot see the 401), so refresh it.
      token = await this.options.getToken(this.attempt > 0)
    } catch {
      if (generation !== this.generation) return
      this.connecting = false
      this.scheduleReconnect()
      return
    }
    if (generation !== this.generation) return
    this.connecting = false
    if (!this.running || this.ws) return

    const scheme = location.protocol === 'https:' ? 'wss' : 'ws'
    const query = new URLSearchParams({
      token,
      deviceId: this.options.deviceId,
      deviceName: this.options.deviceName,
    })
    const ws = new WebSocket(`${scheme}://${location.host}/api/v1/calls/ws?${query}`)
    this.ws = ws
    this.gotHello = false

    ws.onmessage = (event) => {
      let message: ServerMessage
      try {
        message = JSON.parse(String(event.data)) as ServerMessage
      } catch {
        return
      }
      if (message.type === 'hello') {
        // Only now is the server ready to accept messages from us.
        this.gotHello = true
        this.attempt = 0
        this.options.onState('online')
        clearInterval(this.pingTimer)
        this.pingTimer = setInterval(() => this.send({ type: 'ping' }), PING_INTERVAL_MS)
      }
      this.options.onMessage(message)
    }

    ws.onclose = (event) => {
      if (this.ws !== ws) return
      this.ws = null
      this.gotHello = false
      clearInterval(this.pingTimer)
      if (event.code === REPLACED_CLOSE_CODE) {
        this.running = false
        this.options.onState('replaced')
        return
      }
      this.options.onState('offline')
      this.scheduleReconnect()
    }
  }

  private scheduleReconnect() {
    if (!this.running) return
    const delay = Math.min(MAX_BACKOFF_MS, 500 * 2 ** this.attempt) + Math.random() * 300
    this.attempt += 1
    clearTimeout(this.reconnectTimer)
    this.reconnectTimer = setTimeout(() => void this.connect(), delay)
  }
}
