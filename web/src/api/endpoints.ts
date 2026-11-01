import { api } from './client'
import type {
  AdminCallPage,
  AdminStats,
  AdminUserPage,
  AdminUserUpdate,
  AuthResponse,
  BlockedUser,
  CallHistoryItem,
  Contact,
  Todo,
  TodoPage,
  TodoUpdate,
  User,
} from './types'

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

export const contactsApi = {
  list: () => api<{ contacts: Contact[] }>('/contacts'),

  add: (email: string) => api<Contact>('/contacts', { method: 'POST', body: { email } }),

  remove: (userId: string) => api<MessageResponse>(`/contacts/${userId}`, { method: 'DELETE' }),

  blocked: () => api<{ users: BlockedUser[] }>('/blocks'),

  block: (userId: string) => api<MessageResponse>(`/blocks/${userId}`, { method: 'PUT' }),

  unblock: (userId: string) => api<MessageResponse>(`/blocks/${userId}`, { method: 'DELETE' }),
}

export const adminApi = {
  stats: () => api<AdminStats>('/admin/stats'),

  users: (page: number, limit: number, search: string) =>
    api<AdminUserPage>(`/admin/users?${new URLSearchParams({ page: String(page), limit: String(limit), search })}`),

  updateUser: (id: string, changes: AdminUserUpdate) =>
    api<MessageResponse>(`/admin/users/${id}`, { method: 'PATCH', body: changes }),

  calls: (page: number, limit: number) => api<AdminCallPage>(`/admin/calls?page=${page}&limit=${limit}`),
}
