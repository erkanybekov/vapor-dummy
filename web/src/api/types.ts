// Mirrors of the Vapor DTOs (Sources/hello/Presentation/DTOs). Optional Swift
// properties are omitted from the JSON when nil, hence the `?:` fields.

export interface User {
  id: string
  email: string
  username: string
  isActive: boolean
  isAdmin: boolean
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

export interface BlockedUser {
  id: string
  username: string
}

export interface Contact extends BlockedUser {
  /** Always false unless you have added each other. */
  online: boolean
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

export interface AdminStats {
  users: number
  activeUsers: number
  admins: number
  onlineUsers: number
  activeCalls: number
  callsLastDay: number
}

export interface AdminUser extends User {
  online: boolean
}

export interface AdminUserPage {
  users: AdminUser[]
  pagination: PaginationMeta
}

export interface AdminUserUpdate {
  isActive?: boolean
  isAdmin?: boolean
}

export interface AdminCall {
  id: string
  callerId: string
  callerUsername?: string
  calleeId: string
  calleeUsername?: string
  video: boolean
  status: CallStatus
  endReason?: CallEndReason
  startedAt: string
  duration?: number
}

export interface AdminCallPage {
  calls: AdminCall[]
  pagination: PaginationMeta
}
