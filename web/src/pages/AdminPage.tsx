import { useCallback, useEffect, useState } from 'react'
import { ApiError } from '../api/client'
import { adminApi } from '../api/endpoints'
import type { AdminCall, AdminStats, AdminUser, AdminUserUpdate, PaginationMeta } from '../api/types'
import { useAuth } from '../auth/AuthProvider'
import { CALL_STATUS_TEXT, formatDuration, formatWhen } from '../lib/format'
import { ConfirmButton } from '../ui/ConfirmButton'
import { BlockIcon, CheckIcon, ChevronLeftIcon, ChevronRightIcon, PhoneIcon, ShieldIcon, ShieldOffIcon, VideoIcon } from '../ui/icons'
import { useToast } from '../ui/Toast'

const PAGE_SIZE = 20
const REFRESH_MS = 15_000
const SEARCH_DELAY_MS = 300

/**
 * Loads data, keeps it fresh while the tab is visible, and drops answers that
 * arrive after the request changed. `fetcher` must be stable: a new one reloads.
 */
function useRemote<T>(fetcher: () => Promise<T>, failure: string) {
  const [data, setData] = useState<T | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [version, setVersion] = useState(0)
  const reload = useCallback(() => setVersion((value) => value + 1), [])

  useEffect(() => {
    let cancelled = false
    fetcher().then(
      (next) => {
        if (cancelled) return
        setData(next)
        setError(null)
      },
      (caught: unknown) => {
        if (!cancelled) setError(caught instanceof ApiError ? caught.message : failure)
      },
    )
    return () => {
      cancelled = true
    }
  }, [fetcher, failure, version])

  useEffect(() => {
    const timer = setInterval(() => {
      if (!document.hidden) reload()
    }, REFRESH_MS)
    return () => clearInterval(timer)
  }, [reload])

  return { data, error, reload }
}

function LoadError({ error, onRetry }: { error: string; onRetry: () => void }) {
  return (
    <p className="form-error">
      {error}{' '}
      <button className="link-button" onClick={onRetry}>
        Повторить
      </button>
    </p>
  )
}

function Pager({ pagination, onPage }: { pagination: PaginationMeta; onPage: (page: number) => void }) {
  const { page, totalPages } = pagination
  if (totalPages <= 1) return null
  return (
    <nav className="pager" aria-label="Страницы">
      <button className="icon-button" disabled={page <= 1} onClick={() => onPage(page - 1)} aria-label="Назад">
        <ChevronLeftIcon />
      </button>
      <span className="muted">
        {page} из {totalPages}
      </span>
      <button className="icon-button" disabled={page >= totalPages} onClick={() => onPage(page + 1)} aria-label="Вперёд">
        <ChevronRightIcon />
      </button>
    </nav>
  )
}

function StatsGrid({ stats }: { stats: AdminStats }) {
  const tiles: [string, number][] = [
    ['В сети', stats.onlineUsers],
    ['Идёт звонков', stats.activeCalls],
    ['Звонков за сутки', stats.callsLastDay],
    ['Пользователей', stats.users],
    ['Заблокировано', stats.users - stats.activeUsers],
    ['Администраторов', stats.admins],
  ]

  return (
    <dl className="admin-stats">
      {tiles.map(([label, value]) => (
        <div key={label} className="card admin-stat">
          <dt className="muted small">{label}</dt>
          <dd>{value}</dd>
        </div>
      ))}
    </dl>
  )
}

interface UserRowProps {
  user: AdminUser
  isSelf: boolean
  onChange: (user: AdminUser, changes: AdminUserUpdate) => void
}

function UserRow({ user, isSelf, onChange }: UserRowProps) {
  const { username, isActive, isAdmin } = user

  return (
    <li className="list-item">
      <span className={`status-dot ${user.online ? 'online' : ''}`} title={user.online ? 'в сети' : 'не в сети'} aria-hidden="true" />
      <span className="grow admin-who">
        <span className="admin-name">
          <span className="truncate">{username}</span>
          {isAdmin && <span className="badge accent">админ</span>}
          {!isActive && <span className="badge danger">заблокирован</span>}
        </span>
        <span className="muted small block truncate">{user.email}</span>
      </span>
      {user.createdAt && <span className="muted small admin-date">{formatWhen(user.createdAt)}</span>}
      {isSelf ? (
        <span className="badge">это вы</span>
      ) : (
        <span className="list-actions">
          <ConfirmButton
            label={isAdmin ? `Снять права админа: ${username}` : `Сделать админом: ${username}`}
            confirmLabel={isAdmin ? 'Снять?' : 'Админ?'}
            onConfirm={() => onChange(user, { isAdmin: !isAdmin })}
          >
            {isAdmin ? <ShieldOffIcon size={18} /> : <ShieldIcon size={18} />}
          </ConfirmButton>
          <ConfirmButton
            label={isActive ? `Заблокировать: ${username}` : `Разблокировать: ${username}`}
            confirmLabel={isActive ? 'Блок?' : 'Вернуть?'}
            onConfirm={() => onChange(user, { isActive: !isActive })}
          >
            {isActive ? <BlockIcon size={18} /> : <CheckIcon size={18} />}
          </ConfirmButton>
        </span>
      )}
    </li>
  )
}

function UsersCard({ onChanged }: { onChanged: () => void }) {
  const { user: me } = useAuth()
  const toast = useToast()
  const [search, setSearch] = useState('')
  const [query, setQuery] = useState('')
  const [page, setPage] = useState(1)

  useEffect(() => {
    const timer = setTimeout(() => {
      setQuery(search.trim())
      setPage(1)
    }, SEARCH_DELAY_MS)
    return () => clearTimeout(timer)
  }, [search])

  const fetcher = useCallback(() => adminApi.users(page, PAGE_SIZE, query), [page, query])
  const { data, error, reload } = useRemote(fetcher, 'Не удалось загрузить пользователей')

  const change = async (user: AdminUser, changes: AdminUserUpdate) => {
    try {
      await adminApi.updateUser(user.id, changes)
      reload()
      onChanged()
    } catch (caught) {
      toast.show(caught instanceof ApiError ? caught.message : 'Не удалось изменить пользователя', 'error')
    }
  }

  return (
    <section className="card stack">
      <h2>Пользователи {data && <span className="muted small">{data.pagination.total}</span>}</h2>
      <label className="field">
        <span>Поиск</span>
        <input type="search" placeholder="Имя или email" value={search} onChange={(e) => setSearch(e.target.value)} />
      </label>
      {error && <LoadError error={error} onRetry={reload} />}
      {data === null && !error && <p className="muted">Загрузка…</p>}
      {data?.users.length === 0 && <p className="muted">Никого не нашлось.</p>}
      {data && data.users.length > 0 && (
        <ul className="list">
          {data.users.map((user) => (
            <UserRow key={user.id} user={user} isSelf={user.id === me?.id} onChange={(target, changes) => void change(target, changes)} />
          ))}
        </ul>
      )}
      {data && <Pager pagination={data.pagination} onPage={setPage} />}
    </section>
  )
}

function CallRow({ call }: { call: AdminCall }) {
  const caller = call.callerUsername ?? 'Удалённый пользователь'
  const callee = call.calleeId === call.callerId ? 'себе' : (call.calleeUsername ?? 'Удалённый пользователь')

  return (
    <li className="list-item">
      <span className={`list-icon ${call.status === 'completed' ? '' : 'danger-text'}`} title={call.video ? 'Видео' : 'Аудио'}>
        {call.video ? <VideoIcon size={18} /> : <PhoneIcon size={18} />}
      </span>
      <span className="grow admin-who">
        <span className="block truncate">
          {caller} → {callee}
        </span>
        <span className="muted small block">
          {CALL_STATUS_TEXT[call.status]}
          {call.duration != null && ` · ${formatDuration(call.duration)}`}
        </span>
      </span>
      <span className="muted small">{formatWhen(call.startedAt)}</span>
    </li>
  )
}

function CallsCard() {
  const [page, setPage] = useState(1)
  const fetcher = useCallback(() => adminApi.calls(page, PAGE_SIZE), [page])
  const { data, error, reload } = useRemote(fetcher, 'Не удалось загрузить звонки')

  return (
    <section className="card stack">
      <h2>Звонки {data && <span className="muted small">{data.pagination.total}</span>}</h2>
      {error && <LoadError error={error} onRetry={reload} />}
      {data === null && !error && <p className="muted">Загрузка…</p>}
      {data?.calls.length === 0 && <p className="muted">Звонков пока не было.</p>}
      {data && data.calls.length > 0 && (
        <ul className="list">
          {data.calls.map((call) => (
            <CallRow key={call.id} call={call} />
          ))}
        </ul>
      )}
      {data && <Pager pagination={data.pagination} onPage={setPage} />}
    </section>
  )
}

export function AdminPage() {
  const [tab, setTab] = useState<'users' | 'calls'>('users')
  const stats = useRemote(adminApi.stats, 'Не удалось загрузить статистику')

  return (
    <div className="page">
      {stats.error && <LoadError error={stats.error} onRetry={stats.reload} />}
      {stats.data && <StatsGrid stats={stats.data} />}
      <div className="segmented admin-tabs" role="tablist">
        <button role="tab" aria-selected={tab === 'users'} className={tab === 'users' ? 'active' : ''} onClick={() => setTab('users')}>
          Пользователи
        </button>
        <button role="tab" aria-selected={tab === 'calls'} className={tab === 'calls' ? 'active' : ''} onClick={() => setTab('calls')}>
          Звонки
        </button>
      </div>
      {tab === 'users' ? <UsersCard onChanged={stats.reload} /> : <CallsCard />}
    </div>
  )
}
