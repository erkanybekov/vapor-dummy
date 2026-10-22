import { createContext, useContext, useEffect, useState, useSyncExternalStore, type ReactNode } from 'react'
import { getAccessToken, refreshSession } from '../api/client'
import { deviceId, deviceName } from '../lib/device'
import { useToast } from '../ui/Toast'
import { CallManager, type CallSnapshot } from './CallManager'
import { unlockAudio } from './ringtone'

const CallContext = createContext<CallManager | null>(null)

/** Keeps the call connection open while signed in, so calls ring on every page. */
export function CallProvider({ children }: { children: ReactNode }) {
  const toast = useToast()
  const [manager] = useState(
    () =>
      new CallManager({
        deviceId,
        deviceName,
        getToken: async (force) => (force ? (await refreshSession()).accessToken : getAccessToken()),
        onNotice: (text) => toast.show(text),
      }),
  )

  useEffect(() => {
    manager.start()
    return () => manager.stop()
  }, [manager])

  // Browsers only play sound after a user gesture: unlock the ringtone early.
  useEffect(() => {
    document.addEventListener('pointerdown', unlockAudio, { once: true })
    return () => document.removeEventListener('pointerdown', unlockAudio)
  }, [])

  return <CallContext.Provider value={manager}>{children}</CallContext.Provider>
}

export function useCalls(): { manager: CallManager; state: CallSnapshot } {
  const manager = useContext(CallContext)
  if (!manager) throw new Error('useCalls must be used inside <CallProvider>')
  const state = useSyncExternalStore(manager.subscribe, manager.getSnapshot)
  return { manager, state }
}
