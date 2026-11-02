// Wire format of the training chat. Mirrors Sources/hello/Domain/Entities/Chat.swift.

export interface ChatUser {
  id: string
  username: string
}

export interface ChatMessage {
  /** Server-assigned and increasing: sort by it, dedupe by it, resume after it. */
  seq: number
  room: string
  author: ChatUser
  text: string
  sentAt: string
  /** The sender's own id for the message, echoed back as the delivery confirmation. */
  clientId: string
}

export type ChatServerMessage =
  | { type: 'welcome'; room: string; you: ChatUser; online: ChatUser[]; messages: ChatMessage[]; hasMore: boolean }
  | { type: 'message'; message: ChatMessage }
  | { type: 'presence'; online: ChatUser[] }
  | { type: 'typing'; user: ChatUser; isTyping: boolean }
  | { type: 'error'; code: string; message: string; clientId?: string }
  | { type: 'pong' }

export type ChatClientMessage =
  | { type: 'send'; clientId: string; text: string }
  | { type: 'typing'; isTyping: boolean }
  | { type: 'ping' }

export interface ChatHistoryResponse {
  messages: ChatMessage[]
  hasMore: boolean
}

export const MAX_MESSAGE_LENGTH = 2000
