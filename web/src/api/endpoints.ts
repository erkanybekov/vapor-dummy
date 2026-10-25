import { api } from './client'
import type { AuthResponse, CallHistoryItem, Todo, TodoPage, TodoUpdate, User } from './types'

interface MessageResponse {
  message: string
}

export const authApi = {
  login: (email: string, password: string) =>
    api<AuthResponse>('/auth/login', { method: 'POST', body: { email, password }, auth: false }),

  register: (email: string, username: string, password: string) =>
    api<AuthResponse>('/auth/register', { method: 'POST', body: { email, username, password }, auth: false }),

  me: () => api<User>('/auth/me'),

  // Sending the refresh token makes the server revoke it too.
  logout: (refreshToken?: string) =>
    api<MessageResponse>('/auth/logout', { method: 'POST', body: refreshToken ? { refreshToken } : undefined }),
}

export const todosApi = {
  page: (page: number, limit: number) => api<TodoPage>(`/todos?page=${page}&limit=${limit}`),

  create: (title: string, description?: string) =>
    api<Todo>('/todos', { method: 'POST', body: { title, description: description || undefined } }),

  update: (id: string, changes: TodoUpdate) => api<Todo>(`/todos/${id}`, { method: 'PUT', body: changes }),

  toggle: (id: string) => api<Todo>(`/todos/${id}/toggle`, { method: 'PATCH' }),

  remove: (id: string) => api<MessageResponse>(`/todos/${id}`, { method: 'DELETE' }),
}

export const callsApi = {
  history: (limit = 30) => api<{ calls: CallHistoryItem[] }>(`/calls/history?limit=${limit}`),
}
