// Mirrors of the Vapor DTOs (Sources/hello/Presentation/DTOs). Optional Swift
// properties are omitted from the JSON when nil, hence the `?:` fields.

export interface User {
  id: string
  email: string
  username: string
  isActive: boolean
  createdAt?: string
}

export interface AuthResponse {
  accessToken: string
  refreshToken: string
  expiresIn: number
  tokenType: string
  user: User
}

export interface Todo {
  id: string
  title: string
  description?: string
  completed: boolean
  createdAt?: string
  updatedAt?: string
}

export interface PaginationMeta {
  page: number
  limit: number
  total: number
  totalPages: number
}

export interface TodoPage {
  todos: Todo[]
  pagination: PaginationMeta
}

export interface TodoUpdate {
  title?: string
  description?: string
  completed?: boolean
}

export type CallStatus = 'ringing' | 'active' | 'completed' | 'missed' | 'declined' | 'busy' | 'unavailable'

export type CallEndReason =
  | 'hangup'
  | 'cancelled'
  | 'declined'
  | 'timeout'
  | 'busy'
  | 'unavailable'
  | 'answered_elsewhere'
  | 'connection_lost'

export interface CallHistoryItem {
  id: string
  direction: 'outgoing' | 'incoming' | 'self'
  peerUserId: string
  peerUsername?: string
  video: boolean
  status: CallStatus
  endReason?: CallEndReason
  startedAt: string
  answeredAt?: string
  endedAt?: string
  duration?: number
}
