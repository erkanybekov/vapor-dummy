import { describe, expect, it } from 'vitest'
import { computeQuality, parseStats, preferH264, summarize } from './quality'

const report = (bytesSent: number, bytesReceived: number) => [
  { id: 'c1', type: 'codec', mimeType: 'video/H264' },
  { id: 'c2', type: 'codec', mimeType: 'video/VP8' },
  {
    id: 'out', type: 'outbound-rtp', kind: 'video', codecId: 'c1', frameWidth: 1280, frameHeight: 720,
    framesPerSecond: 29.6, bytesSent, qualityLimitationReason: 'bandwidth',
  },
  { id: 'outA', type: 'outbound-rtp', kind: 'audio', bytesSent: 999_999 },
  {
    id: 'in', type: 'inbound-rtp', kind: 'video', codecId: 'c2', frameWidth: 640, frameHeight: 480,
    framesPerSecond: 24, bytesReceived, packetsLost: 2, packetsReceived: 198,
  },
  { id: 'l', type: 'local-candidate', candidateType: 'host' },
  { id: 'r', type: 'remote-candidate', candidateType: 'srflx' },
  { id: 'p0', type: 'candidate-pair', state: 'in-progress', nominated: false, currentRoundTripTime: 9 },
  { id: 'p1', type: 'candidate-pair', state: 'succeeded', nominated: true, currentRoundTripTime: 0.042, localCandidateId: 'l', remoteCandidateId: 'r' },
]

describe('call quality', () => {
  it('reads video streams, codecs and the active path from a stats report', () => {
    const stats = parseStats(report(1000, 2000), 0)
    expect(stats.sent).toMatchObject({ width: 1280, height: 720, codec: 'H264', limitation: 'bandwidth' })
    expect(stats.received).toMatchObject({ width: 640, height: 480, codec: 'VP8', packetsLost: 2 })
    expect(stats.rttMs).toBeCloseTo(42)
    expect(stats.path).toBe('host ↔ srflx')
  })

  it('computes bitrates from two samples', () => {
    const first = parseStats(report(0, 0), 0)
    const second = parseStats(report(500_000, 250_000), 2000) // 2 s later
    const quality = computeQuality(second, first)
    expect(quality.sent).toMatchObject({ resolution: '1280×720', fps: 30, kbps: 2000 })
    expect(quality.received).toMatchObject({ resolution: '640×480', fps: 24, kbps: 1000 })
    expect(quality.lossPercent).toBeCloseTo(1)
    expect(summarize(quality)).toContain('↑ 1280×720 30fps 2000kbps H264 limit=bandwidth')
  })

  it('reports zero bitrate for the first sample', () => {
    expect(computeQuality(parseStats(report(10, 10), 0)).sent?.kbps).toBe(0)
  })

  it('moves H.264 to the front and keeps every other codec', () => {
    const codecs = [{ mimeType: 'video/VP8' }, { mimeType: 'video/rtx' }, { mimeType: 'video/H264' }, { mimeType: 'video/AV1' }]
    expect(preferH264(codecs).map((c) => c.mimeType)).toEqual(['video/H264', 'video/VP8', 'video/rtx', 'video/AV1'])
  })
})
