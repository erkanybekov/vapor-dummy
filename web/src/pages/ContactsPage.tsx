import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { ApiError } from '../api/client'
import { contactsApi } from '../api/endpoints'
import type { BlockedUser, Contact } from '../api/types'
import { useCalls } from '../calls/CallProvider'
import { ConfirmButton } from '../ui/ConfirmButton'
import { BlockIcon, PhoneIcon, UserMinusIcon, VideoIcon } from '../ui/icons'
import { useToast } from '../ui/Toast'

const ADD_ERROR_TEXT: Record<number, string> = {
  400: 'Себя добавить нельзя',
  404: 'Пользователь с таким email не найден',
  409: 'Этот пользователь заблокирован: сначала разблокируйте его',
  429: 'Слишком много попыток, подождите',
}

function errorText(error: unknown, fallback: string) {
  return error instanceof ApiError ? (ADD_ERROR_TEXT[error.status] ?? error.message) : fallback
}

function AddContactCard({ onAdded }: { onAdded: () => void }) {
  const toast = useToast()
  const [email, setEmail] = useState('')
  const [saving, setSaving] = useState(false)

  const add = async (event: FormEvent) => {
    event.preventDefault()
    setSaving(true)
    try {
      await contactsApi.add(email.trim())
      setEmail('')
      onAdded()
    } catch (error) {
      toast.show(errorText(error, 'Не удалось добавить контакт'), 'error')
    } finally {
      setSaving(false)
    }
  }

  return (
    <section className="card">
      <h2>Добавить контакт</h2>
      <form className="stack" onSubmit={(event) => void add(event)}>
        <label className="field">
          <span>Email</span>
          <input type="email" required value={email} onChange={(e) => setEmail(e.target.value)} />
          <small className="muted">Человек не получит уведомления. Статус «в сети» виден, когда вы добавили друг друга.</small>
        </label>
        <button className="button primary" type="submit" disabled={saving || !email.trim()}>
          Добавить
        </button>
      </form>
    </section>
  )
}

interface ContactRowProps {
  contact: Contact
  onRemove: (contact: Contact) => void
  onBlock: (contact: Contact) => void
}

function ContactRow({ contact, onRemove, onBlock }: ContactRowProps) {
  const { manager, state } = useCalls()
  const canCall = state.connection === 'online' && state.call === null
  const call = (video: boolean) => void manager.startCall({ userId: contact.id, name: contact.username }, video)

  return (
    <li className="list-item">
      <span className={`status-dot ${contact.online ? 'online' : ''}`} aria-hidden="true" />
      <span className="grow truncate">
        {contact.username}
        <span className="muted small block">{contact.online ? 'в сети' : 'не в сети'}</span>
      </span>
      <span className="list-actions">
        <button className="icon-button" onClick={() => call(true)} disabled={!canCall} aria-label={`Видеозвонок: ${contact.username}`} title="Видеозвонок">
          <VideoIcon size={18} />
        </button>
        <button className="icon-button" onClick={() => call(false)} disabled={!canCall} aria-label={`Аудиозвонок: ${contact.username}`} title="Аудиозвонок">
          <PhoneIcon size={18} />
        </button>
        <ConfirmButton label={`Удалить из контактов: ${contact.username}`} confirmLabel="Удалить?" onConfirm={() => onRemove(contact)}>
          <UserMinusIcon size={18} />
        </ConfirmButton>
        <ConfirmButton label={`Заблокировать: ${contact.username}`} confirmLabel="Блок?" onConfirm={() => onBlock(contact)}>
          <BlockIcon size={18} />
        </ConfirmButton>
      </span>
    </li>
  )
}

export function ContactsPage() {
  const { state } = useCalls()
  const toast = useToast()
  const [contacts, setContacts] = useState<Contact[] | null>(null)
  const [blocked, setBlocked] = useState<BlockedUser[]>([])
  const [error, setError] = useState<string | null>(null)
  const online = state.connection === 'online'

  const load = useCallback(async () => {
    try {
      const [list, blockedList] = await Promise.all([contactsApi.list(), contactsApi.blocked()])
      setContacts(list.contacts)
      setBlocked(blockedList.users)
      setError(null)
    } catch (caught) {
      setError(caught instanceof ApiError ? caught.message : 'Не удалось загрузить контакты')
    }
  }, [])

  // Also after reconnecting: changes made while offline were not announced.
  useEffect(() => {
    void load()
  }, [load, state.contactChanges, online])

  const change = async (action: Promise<unknown>, failure: string) => {
    try {
      await action
      await load()
    } catch {
      toast.show(failure, 'error')
    }
  }

  return (
    <div className="page">
      <div className="columns">
        <div className="stack">
          <AddContactCard onAdded={() => void load()} />
          {blocked.length > 0 && (
            <section className="card">
              <h2>Заблокированные</h2>
              <ul className="list">
                {blocked.map((user) => (
                  <li key={user.id} className="list-item">
                    <span className="grow truncate">{user.username}</span>
                    <button className="link-button" onClick={() => void change(contactsApi.unblock(user.id), 'Не удалось разблокировать')}>
                      Разблокировать
                    </button>
                  </li>
                ))}
              </ul>
              <p className="hint">Заблокированный не сможет вам дозвониться: для него вы просто не в сети.</p>
            </section>
          )}
        </div>
        <section className="card">
          <h2>Контакты</h2>
          {error && (
            <p className="form-error">
              {error}{' '}
              <button className="link-button" onClick={() => void load()}>
                Повторить
              </button>
            </p>
          )}
          {contacts === null && !error && <p className="muted">Загрузка…</p>}
          {contacts?.length === 0 && <p className="muted">Контактов пока нет.</p>}
          {contacts && contacts.length > 0 && (
            <ul className="list">
              {contacts.map((contact) => (
                <ContactRow
                  key={contact.id}
                  contact={contact}
                  onRemove={(target) => void change(contactsApi.remove(target.id), 'Не удалось удалить контакт')}
                  onBlock={(target) => void change(contactsApi.block(target.id), 'Не удалось заблокировать')}
                />
              ))}
            </ul>
          )}
        </section>
      </div>
    </div>
  )
}
