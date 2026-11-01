import { useEffect, useState, type ReactNode } from 'react'

const CONFIRM_MS = 3000

interface Props {
  /** What the button does: its tooltip and accessible name. */
  label: string
  /** Shown next to the icon after the first click. */
  confirmLabel: string
  disabled?: boolean
  onConfirm: () => void
  children: ReactNode
}

/** An icon button for an action that is annoying to undo: the second click runs it. */
export function ConfirmButton({ label, confirmLabel, disabled, onConfirm, children }: Props) {
  const [armed, setArmed] = useState(false)

  useEffect(() => {
    if (!armed) return
    const timer = setTimeout(() => setArmed(false), CONFIRM_MS)
    return () => clearTimeout(timer)
  }, [armed])

  const click = () => {
    if (!armed) return setArmed(true)
    setArmed(false)
    onConfirm()
  }

  return (
    <button
      className={`icon-button ${armed ? 'confirm' : ''}`}
      onClick={click}
      disabled={disabled}
      aria-label={armed ? `${label}: нажмите ещё раз` : label}
      title={label}
    >
      {children}
      {armed && <span className="small">{confirmLabel}</span>}
    </button>
  )
}
