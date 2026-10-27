import type { ReactNode } from 'react'
import { BrowserRouter, Link, Navigate, Route, Routes, useLocation } from 'react-router'
import { AppLayout } from './AppLayout'
import { AuthProvider, useAuth } from './auth/AuthProvider'
import { CallProvider } from './calls/CallProvider'
import { AuthPage } from './pages/AuthPage'
import { CallsPage } from './pages/CallsPage'
import { ChatPage } from './pages/ChatPage'
import { GuidePage } from './pages/GuidePage'
import { TodosPage } from './pages/TodosPage'
import { ToastProvider } from './ui/Toast'

function Splash() {
  return (
    <div className="splash">
      <span className="brand-mark large" aria-hidden="true" />
      <p className="muted">Загрузка…</p>
    </div>
  )
}

function RequireAuth({ children }: { children: ReactNode }) {
  const { user, checking } = useAuth()
  const location = useLocation()
  if (checking) return <Splash />
  if (!user) return <Navigate to="/login" replace state={{ from: location.pathname }} />
  return children
}

function GuestOnly({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  return user ? <Navigate to="/calls" replace /> : children
}

function NotFound() {
  return (
    <main className="auth-page">
      <div className="auth-card">
        <h1>404</h1>
        <p className="muted">Такой страницы нет.</p>
        <Link className="button primary" to="/">
          На главную
        </Link>
      </div>
    </main>
  )
}

export function App() {
  return (
    <ToastProvider>
      <AuthProvider>
        <BrowserRouter>
          <Routes>
            <Route
              path="/login"
              element={
                <GuestOnly>
                  <AuthPage />
                </GuestOnly>
              }
            />
            <Route
              element={
                <RequireAuth>
                  <CallProvider>
                    <AppLayout />
                  </CallProvider>
                </RequireAuth>
              }
            >
              <Route index element={<Navigate to="/calls" replace />} />
              <Route path="/calls" element={<CallsPage />} />
              <Route path="/todos" element={<TodosPage />} />
              <Route path="/chat" element={<ChatPage />} />
              <Route path="/guide" element={<GuidePage />} />
            </Route>
            <Route path="*" element={<NotFound />} />
          </Routes>
        </BrowserRouter>
      </AuthProvider>
    </ToastProvider>
  )
}
