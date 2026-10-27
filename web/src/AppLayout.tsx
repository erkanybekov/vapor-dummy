import { NavLink, Outlet } from 'react-router'
import { useAuth } from './auth/AuthProvider'
import { CallOverlay } from './calls/CallOverlay'
import { useCalls } from './calls/CallProvider'
import type { ConnectionState } from './calls/SignalingClient'
import { BookIcon, ChecklistIcon, LogOutIcon, MessageIcon, PhoneIcon } from './ui/icons'

const CONNECTION_TEXT: Record<ConnectionState, string> = {
  online: 'Онлайн: можно звонить',
  connecting: 'Подключение к серверу звонков…',
  offline: 'Нет связи с сервером звонков',
  replaced: 'Звонки открыты в другой вкладке',
}

function NavItems() {
  return (
    <>
      <NavLink to="/calls" className="nav-link">
        <PhoneIcon size={18} />
        <span>Звонки</span>
      </NavLink>
      <NavLink to="/todos" className="nav-link">
        <ChecklistIcon size={18} />
        <span>Задачи</span>
      </NavLink>
      <NavLink to="/chat" className="nav-link">
        <MessageIcon size={18} />
        <span>Чат</span>
      </NavLink>
      <NavLink to="/guide" className="nav-link">
        <BookIcon size={18} />
        <span>Гайд</span>
      </NavLink>
    </>
  )
}

export function AppLayout() {
  const { user, logout } = useAuth()
  const { manager, state } = useCalls()

  return (
    <div className="app">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true" />
          Vapor Calls
        </div>
        <nav className="topnav" aria-label="Разделы">
          <NavItems />
        </nav>
        <div className="topbar-end">
          <span className={`status-dot ${state.connection}`} title={CONNECTION_TEXT[state.connection]} role="img" aria-label={CONNECTION_TEXT[state.connection]} />
          <span className="username" title={user?.email}>
            {user?.username}
          </span>
          <button className="icon-button" onClick={() => void logout()} aria-label="Выйти" title="Выйти">
            <LogOutIcon size={18} />
          </button>
        </div>
      </header>

      {state.connection === 'replaced' && (
        <div className="banner warning centered">
          Эта вкладка отключена от звонков: устройство подключилось в другом окне.{' '}
          <button className="link-button" onClick={() => manager.reconnect()}>
            Подключиться здесь
          </button>
        </div>
      )}

      <main className="content">
        <Outlet />
      </main>

      <nav className="bottomnav" aria-label="Разделы">
        <NavItems />
      </nav>

      <CallOverlay />
    </div>
  )
}
