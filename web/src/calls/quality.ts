// Call quality from WebRTC statistics (RTCPeerConnection.getStats()): what we
// send and receive, how the network behaves, and why the encoder lowered
// quality. Pure functions, so they are easy to test.

export interface VideoStats {
  width: number
  height: number
  fps: number
  bytes: number
  codec?: string
  /** Why the encoder lowered quality: "bandwidth", "cpu", "other" or "none". */
  limitation?: string
  packetsLost: number
  packetsReceived: number
}

export interface MediaStats {
  timestamp: number
  sent?: VideoStats
  received?: VideoStats
  rttMs?: number
  /** Candidate types of the active path, e.g. "host ↔ srflx" (relay = through TURN). */
  path?: string
}

export interface VideoQuality {
  resolution: string
  fps: number
  kbps: number
  codec?: string
  limitation?: string
}

export interface CallQuality {
  sent?: VideoQuality
  received?: VideoQuality
  rttMs?: number
  lossPercent?: number
  path?: string
}

type Stat = Record<string, unknown> & { id: string; type: string }

const num = (value: unknown): number | undefined => (typeof value === 'number' ? value : undefined)
const str = (value: unknown): string | undefined => (typeof value === 'string' ? value : undefined)

export function parseStats(report: Iterable<Stat>, timestamp = Date.now()): MediaStats {
  const all = [...report]
  const byId = new Map(all.map((stat) => [stat.id, stat]))
  const codecOf = (stat: Stat) => str(byId.get(str(stat.codecId) ?? '')?.mimeType)?.replace('video/', '')
  const result: MediaStats = { timestamp }

  for (const stat of all) {
    if (stat.type === 'outbound-rtp' && stat.kind === 'video') {
      result.sent = {
        width: num(stat.frameWidth) ?? 0,
        height: num(stat.frameHeight) ?? 0,
        fps: num(stat.framesPerSecond) ?? 0,
        bytes: num(stat.bytesSent) ?? 0,
        codec: codecOf(stat),
        limitation: str(stat.qualityLimitationReason),
        packetsLost: 0,
        packetsReceived: 0,
      }
    } else if (stat.type === 'inbound-rtp' && stat.kind === 'video') {
      result.received = {
        width: num(stat.frameWidth) ?? 0,
        height: num(stat.frameHeight) ?? 0,
        fps: num(stat.framesPerSecond) ?? 0,
        bytes: num(stat.bytesReceived) ?? 0,
        codec: codecOf(stat),
        packetsLost: num(stat.packetsLost) ?? 0,
        packetsReceived: num(stat.packetsReceived) ?? 0,
      }
    } else if (stat.type === 'candidate-pair' && stat.state === 'succeeded' && stat.nominated === true) {
      const rtt = num(stat.currentRoundTripTime)
      if (rtt !== undefined) result.rttMs = rtt * 1000
      const local = str(byId.get(str(stat.localCandidateId) ?? '')?.candidateType)
      const remote = str(byId.get(str(stat.remoteCandidateId) ?? '')?.candidateType)
      if (local && remote) result.path = `${local} ↔ ${remote}`
    }
  }
  return result
}

function video(current: VideoStats | undefined, previous: VideoStats | undefined, seconds: number): VideoQuality | undefined {
  if (!current) return undefined
  const kbps = previous && seconds > 0 ? Math.max(0, Math.round(((current.bytes - previous.bytes) * 8) / seconds / 1000)) : 0
  return {
    resolution: current.width > 0 ? `${current.width}×${current.height}` : '—',
    fps: Math.round(current.fps),
    kbps,
    codec: current.codec,
    limitation: current.limitation,
  }
}

/** Bitrates need two samples; pass the previous one. */
export function computeQuality(current: MediaStats, previous?: MediaStats): CallQuality {
  const seconds = previous ? (current.timestamp - previous.timestamp) / 1000 : 0
  const received = current.received
  const total = received ? received.packetsLost + received.packetsReceived : 0
  return {
    sent: video(current.sent, previous?.sent, seconds),
    received: video(received, previous?.received, seconds),
    rttMs: current.rttMs === undefined ? undefined : Math.round(current.rttMs),
    lossPercent: received && total > 0 ? (received.packetsLost / total) * 100 : undefined,
    path: current.path,
  }
}

export function summarize(quality: CallQuality): string {
  const parts: string[] = []
  const { sent, received } = quality
  if (sent) parts.push(`↑ ${sent.resolution} ${sent.fps}fps ${sent.kbps}kbps ${sent.codec ?? '?'} limit=${sent.limitation ?? '?'}`)
  if (received) parts.push(`↓ ${received.resolution} ${received.fps}fps ${received.kbps}kbps ${received.codec ?? '?'}`)
  if (quality.rttMs !== undefined) parts.push(`rtt ${quality.rttMs}ms`)
  if (quality.lossPercent !== undefined) parts.push(`loss ${quality.lossPercent.toFixed(1)}%`)
  if (quality.path) parts.push(quality.path)
  return parts.join(' · ')
}

/**
 * Codec list with H.264 first: Apple devices (and most Macs/PCs) encode it in
 * hardware, so the picture stays sharp instead of the CPU forcing a lower
 * resolution. The rest stay as fallbacks.
 */
export function preferH264<T extends { mimeType: string }>(codecs: T[]): T[] {
  const isH264 = (codec: T) => codec.mimeType.toLowerCase() === 'video/h264'
  return [...codecs.filter(isH264), ...codecs.filter((codec) => !isH264(codec))]
}
