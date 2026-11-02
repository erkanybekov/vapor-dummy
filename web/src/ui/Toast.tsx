import { createContext, useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'

type ToastKind = 'info' | 'error'

interface ToastItem {
  id: number
  text: string
  kind: ToastKind
}

interface ToastApi {
  show: (text: string, kind?: ToastKind) => void
}

const ToastContext = createContext<ToastApi | null>(null)

export function ToastProvider({ children }: { children: ReactNode }) {
  const [items, setItems] = useState<ToastItem[]>([])
  const nextId = useRef(1)

  const show = useCallback((text: string, kind: ToastKind = 'info') => {
    const id = nextId.current++
    // Same text twice in a row (e.g. a retry loop) shows once.
    setItems((current) => [...current.filter((item) => item.text !== text), { id, text, kind }].slice(-3))
    setTimeout(() => setItems((current) => current.filter((item) => item.id !== id)), 4000)
  }, [])

  const api = useMemo(() => ({ show }), [show])

  return (
    <ToastContext.Provider value={api}>
      {children}
      <div className="toasts" role="status" aria-live="polite">
        {items.map((item) => (
          <div key={item.id} className={`toast toast-${item.kind}`}>
            {item.text}
          </div>
        ))}
      </div>
    </ToastContext.Provider>
  )
}

export function useToast(): ToastApi {
  const api = useContext(ToastContext)
  if (!api) throw new Error('useToast must be used inside <ToastProvider>')
  return api
}
