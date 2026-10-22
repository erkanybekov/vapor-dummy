import { useEffect, useState, type FormEvent } from 'react'
import { useLocation, useNavigate } from 'react-router'
import { ApiError } from '../api/client'
import { useAuth } from '../auth/AuthProvider'

type Mode = 'login' | 'register'

function passwordProblem(password: string): string | null {
  if (password.length < 8) return 'Минимум 8 символов'
  if (!/[A-Z]/.test(password) || !/[a-z]/.test(password) || !/\d/.test(password)) {
    return 'Нужны заглавная и строчная латинские буквы и цифра'
  }
  return null
}

export function AuthPage() {
  const { login, register } = useAuth()
  const navigate = useNavigate()
  const location = useLocation()
  const from = (location.state as { from?: string } | null)?.from ?? '/calls'

  const [mode, setMode] = useState<Mode>('login')
  const [email, setEmail] = useState('')
  const [username, setUsername] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [slow, setSlow] = useState(false)

  // The free Render instance sleeps when idle; the first request can take a minute.
  useEffect(() => {
    if (!busy) return setSlow(false)
    const timer = setTimeout(() => setSlow(true), 4000)
    return () => clearTimeout(timer)
  }, [busy])

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    if (mode === 'register') {
      const problem = passwordProblem(password)
      if (problem) return setError(problem)
    }
    setBusy(true)
    try {
      if (mode === 'login') await login(email.trim(), password)
      else await register(email.trim(), username.trim() || email.split('@')[0] || 'user', password)
      navigate(from, { replace: true })
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : 'Что-то пошло не так')
    } finally {
      setBusy(false)
    }
  }

  return (
    <main className="auth-page">
      <div className="auth-card">
        <div className="brand brand-large">
          <span className="brand-mark" aria-hidden="true" />
          Vapor Calls
        </div>
        <p className="muted">Видеозвонки между вашими устройствами и задачи — на Swift-бэкенде.</p>

        <div className="segmented" role="tablist">
          <button role="tab" aria-selected={mode === 'login'} className={mode === 'login' ? 'active' : ''} onClick={() => setMode('login')}>
            Вход
          </button>
          <button role="tab" aria-selected={mode === 'register'} className={mode === 'register' ? 'active' : ''} onClick={() => setMode('register')}>
            Регистрация
          </button>
        </div>

        <form className="stack" onSubmit={submit}>
          <label className="field">
            <span>Email</span>
            <input type="email" autoComplete="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          </label>
          {mode === 'register' && (
            <label className="field">
              <span>Имя</span>
              <input autoComplete="nickname" placeholder={email.split('@')[0] || 'Как вас называть'} value={username} onChange={(e) => setUsername(e.target.value)} />
            </label>
          )}
          <label className="field">
            <span>Пароль</span>
            <input
              type="password"
              autoComplete={mode === 'login' ? 'current-password' : 'new-password'}
              required
              value={password}
              onChange={(e) => setPassword(e.target.value)}
            />
            {mode === 'register' && <small className="muted">8+ символов, A–Z, a–z и цифра</small>}
          </label>

          {error && (
            <p className="form-error" role="alert">
              {error}
            </p>
          )}

          <button className="button primary" type="submit" disabled={busy}>
            {busy ? 'Подождите…' : mode === 'login' ? 'Войти' : 'Создать аккаунт'}
          </button>
          {slow && <p className="muted small">Сервер на бесплатном тарифе просыпается — это может занять до минуты.</p>}
        </form>
      </div>
    </main>
  )
}
