import { describe, expect, it } from 'vitest'
import { mergeMessages } from './ChatClient'
import type { ChatMessage } from './protocol'

const message = (seq: number, text = `m${seq}`): ChatMessage => ({
  seq,
  room: 'general',
  author: { id: 'a', username: 'alice' },
  text,
  sentAt: '2026-10-27T18:00:00Z',
  clientId: `c${seq}`,
})

describe('mergeMessages', () => {
  it('keeps seq order whatever order messages arrive in', () => {
    expect(mergeMessages([message(1), message(3)], [message(2)]).map((m) => m.seq)).toEqual([1, 2, 3])
  })

  it('drops duplicates of the same seq, keeping the newer copy', () => {
    const merged = mergeMessages([message(1), message(2, 'old')], [message(2, 'new'), message(3)])
    expect(merged.map((m) => m.text)).toEqual(['m1', 'new', 'm3'])
  })
})
