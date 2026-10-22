// Wire format of the call WebSocket. Mirrors Sources/hello/Domain/Entities/SignalingMessage.swift.

import type { CallEndReason } from '../api/types'

export type CallRole = 'caller' | 'callee'

export interface CallPeer {
  userId: string
  username: string
  deviceId: string
  deviceName: string
}

export interface CallUser {
  id: string
  username: string
}

export interface IceServerConfig {
  urls: string[]
  username?: string
  credential?: string
}

export interface SignalPayload {
  kind: 'offer' | 'answer' | 'candidate'
  sdp?: string
  candidate?: RTCIceCandidateInit
}

export type ServerMessage =
  | { type: 'hello'; userId: string; deviceId: string; iceServers: IceServerConfig[] }
  | { type: 'presence'; devices: CallPeer[] }
  | { type: 'call.ringing'; callId: string; callee: CallUser; devices: number }
  | { type: 'call.incoming'; callId: string; caller: CallPeer; video: boolean }
  | { type: 'call.accepted'; callId: string; peer: CallPeer; role: CallRole; video: boolean }
  | { type: 'call.resumed'; callId: string; peer: CallPeer; role: CallRole; video: boolean }
  | { type: 'call.reconnecting'; callId: string }
  | { type: 'call.ended'; callId: string; reason: CallEndReason }
  | { type: 'call.signal'; callId: string; from: string; signal: SignalPayload }
  | { type: 'error'; code: string; message: string; callId?: string }
  | { type: 'pong' }

export type ClientMessage =
  | { type: 'call.invite'; calleeEmail?: string; calleeId?: string; video: boolean }
  | { type: 'call.accept' | 'call.decline' | 'call.hangup'; callId: string }
  | { type: 'call.signal'; callId: string; signal: SignalPayload }
  | { type: 'ping' }

export const ERROR_TEXT: Record<string, string> = {
  user_not_found: 'Пользователь не найден',
  already_in_call: 'Сначала завершите текущий звонок',
  call_not_found: 'Звонок уже завершён',
  rate_limited: 'Слишком много запросов, подождите',
  too_many_devices: 'Подключено слишком много устройств',
}

export const END_REASON_TEXT: Record<CallEndReason, string> = {
  hangup: 'Звонок завершён',
  cancelled: 'Звонок отменён',
  declined: 'Отклонено',
  timeout: 'Нет ответа',
  busy: 'Занято',
  unavailable: 'Нет устройств онлайн',
  answered_elsewhere: 'Ответили на другом устройстве',
  connection_lost: 'Связь потеряна',
}
