import { useCallback, useEffect, useState, type FormEvent } from 'react'
import { ApiError } from '../api/client'
import { todosApi } from '../api/endpoints'
import type { Todo, TodoPage } from '../api/types'
import { plural } from '../lib/format'
import { ChevronLeftIcon, ChevronRightIcon, EditIcon, PlusIcon, TrashIcon } from '../ui/icons'
import { useToast } from '../ui/Toast'

const PAGE_SIZE = 10

function message(error: unknown, fallback: string): string {
  return error instanceof ApiError ? error.message : fallback
}

function NewTodoForm({ onCreated }: { onCreated: () => void }) {
  const toast = useToast()
  const [title, setTitle] = useState('')
  const [description, setDescription] = useState('')
  const [expanded, setExpanded] = useState(false)
  const [busy, setBusy] = useState(false)

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (!title.trim()) return
    setBusy(true)
    try {
      await todosApi.create(title.trim(), description.trim() || undefined)
      setTitle('')
      setDescription('')
      setExpanded(false)
      onCreated()
    } catch (error) {
      toast.show(message(error, 'Не удалось создать задачу'), 'error')
    } finally {
      setBusy(false)
    }
  }

  return (
    <form className="card stack" onSubmit={submit}>
      <div className="row">
        <input
          className="grow"
          placeholder="Новая задача"
          maxLength={200}
          value={title}
          onChange={(e) => setTitle(e.target.value)}
          aria-label="Название задачи"
        />
        <button className="button primary" type="submit" disabled={busy || !title.trim()}>
          <PlusIcon /> Добавить
        </button>
      </div>
      {expanded ? (
        <textarea
          placeholder="Описание (необязательно)"
          maxLength={1000}
          rows={3}
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          aria-label="Описание задачи"
        />
      ) : (
        <button type="button" className="link-button align-start" onClick={() => setExpanded(true)}>
          + описание
        </button>
      )}
    </form>
  )
}

function TodoRow({ todo, onChanged, onDeleted }: { todo: Todo; onChanged: (todo: Todo) => void; onDeleted: () => void }) {
  const toast = useToast()
  const [editing, setEditing] = useState(false)
  const [title, setTitle] = useState(todo.title)
  const [description, setDescription] = useState(todo.description ?? '')
  const [confirmDelete, setConfirmDelete] = useState(false)

  useEffect(() => {
    if (!confirmDelete) return
    const timer = setTimeout(() => setConfirmDelete(false), 3000)
    return () => clearTimeout(timer)
  }, [confirmDelete])

  const toggle = async () => {
    onChanged({ ...todo, completed: !todo.completed }) // optimistic
    try {
      onChanged(await todosApi.toggle(todo.id))
    } catch (error) {
      onChanged(todo)
      toast.show(message(error, 'Не удалось обновить задачу'), 'error')
    }
  }

  const save = async (event: FormEvent) => {
    event.preventDefault()
    if (!title.trim()) return
    try {
      // An empty string clears the description (null would keep the old one).
      onChanged(await todosApi.update(todo.id, { title: title.trim(), description: description.trim() }))
      setEditing(false)
    } catch (error) {
      toast.show(message(error, 'Не удалось сохранить'), 'error')
    }
  }

  const remove = async () => {
    if (!confirmDelete) return setConfirmDelete(true)
    try {
      await todosApi.remove(todo.id)
      onDeleted()
    } catch (error) {
      toast.show(message(error, 'Не удалось удалить'), 'error')
    }
  }

  if (editing) {
    return (
      <li className="todo editing">
        <form className="stack grow" onSubmit={save}>
          <input value={title} maxLength={200} onChange={(e) => setTitle(e.target.value)} aria-label="Название" autoFocus />
          <textarea value={description} maxLength={1000} rows={2} placeholder="Описание" onChange={(e) => setDescription(e.target.value)} aria-label="Описание" />
          <div className="row end">
            <button
              type="button"
              className="button"
              onClick={() => {
                setTitle(todo.title)
                setDescription(todo.description ?? '')
                setEditing(false)
              }}
            >
              Отмена
            </button>
            <button type="submit" className="button primary" disabled={!title.trim()}>
              Сохранить
            </button>
          </div>
        </form>
      </li>
    )
  }

  return (
    <li className={`todo ${todo.completed ? 'done' : ''}`}>
      <input type="checkbox" className="checkbox" checked={todo.completed} onChange={() => void toggle()} aria-label={todo.title} />
      <div className="grow todo-text">
        <div className="todo-title">{todo.title}</div>
        {todo.description && <div className="muted small">{todo.description}</div>}
      </div>
      <button className="icon-button" onClick={() => setEditing(true)} aria-label="Редактировать" title="Редактировать">
        <EditIcon size={18} />
      </button>
      <button
        className={`icon-button ${confirmDelete ? 'confirm' : ''}`}
        onClick={() => void remove()}
        aria-label={confirmDelete ? 'Точно удалить?' : 'Удалить'}
        title={confirmDelete ? 'Нажмите ещё раз, чтобы удалить' : 'Удалить'}
      >
        <TrashIcon size={18} />
        {confirmDelete && <span className="small">Удалить?</span>}
      </button>
    </li>
  )
}

export function TodosPage() {
  const [page, setPage] = useState(1)
  const [data, setData] = useState<TodoPage | null>(null)
  const [error, setError] = useState<string | null>(null)

  const load = useCallback(async (target: number) => {
    try {
      const result = await todosApi.page(target, PAGE_SIZE)
      // Deleting the last item of the last page: step back a page.
      if (result.todos.length === 0 && target > 1) return setPage(target - 1)
      setData(result)
      setError(null)
    } catch (caught) {
      setError(message(caught, 'Не удалось загрузить задачи'))
    }
  }, [])

  useEffect(() => {
    void load(page)
  }, [load, page])

  const replace = (todo: Todo) =>
    setData((current) => current && { ...current, todos: current.todos.map((t) => (t.id === todo.id ? todo : t)) })

  const total = data?.pagination.total ?? 0
  const totalPages = Math.max(1, data?.pagination.totalPages ?? 1)
  const doneOnPage = data?.todos.filter((t) => t.completed).length ?? 0

  return (
    <div className="page narrow">
      <div className="page-header">
        <h1>Задачи</h1>
        {data && (
          <span className="muted">
            {total} {plural(total, ['задача', 'задачи', 'задач'])}
            {data.todos.length > 0 && ` · на странице выполнено ${doneOnPage} из ${data.todos.length}`}
          </span>
        )}
      </div>

      <NewTodoForm
        onCreated={() => {
          if (page === 1) void load(1)
          else setPage(1)
        }}
      />

      {error && (
        <div className="banner error">
          {error}{' '}
          <button className="link-button" onClick={() => void load(page)}>
            Повторить
          </button>
        </div>
      )}

      {!data && !error && <p className="muted">Загрузка…</p>}

      {data && data.todos.length === 0 && (
        <div className="empty">
          <p>Задач нет.</p>
          <p className="muted small">Добавьте первую — она сохранится в Postgres через Vapor API.</p>
        </div>
      )}

      {data && data.todos.length > 0 && (
        <ul className="card todo-list">
          {data.todos.map((todo) => (
            <TodoRow key={todo.id} todo={todo} onChanged={replace} onDeleted={() => void load(page)} />
          ))}
        </ul>
      )}

      {totalPages > 1 && (
        <nav className="pager" aria-label="Страницы">
          <button className="icon-button" disabled={page <= 1} onClick={() => setPage(page - 1)} aria-label="Назад">
            <ChevronLeftIcon />
          </button>
          <span className="muted">
            {page} из {totalPages}
          </span>
          <button className="icon-button" disabled={page >= totalPages} onClick={() => setPage(page + 1)} aria-label="Вперёд">
            <ChevronRightIcon />
          </button>
        </nav>
      )}
    </div>
  )
}
