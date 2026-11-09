// One viewer controller per signed-in account for the whole admin panel, so an
// unlocked "web access from any browser" key survives moving between pages but
// never a reload (it lives in memory only). Locks itself after 30 minutes
// without activity (owner decision D4) and on sign-out.

import React from 'react'
import { e2eeHttp, getProfile } from './api'
import { getAccessToken, isAuthenticated, subscribeAuth } from './auth'
import { ViewerController } from '../e2ee/controller'
import { idleExpired } from './privateViewerCore'

let current: { ctl: ViewerController; ready: Promise<ViewerController> } | null = null
let lastActive = Date.now()
let timer: ReturnType<typeof setInterval> | null = null

function touch() {
  lastActive = Date.now()
}

function startIdleWatch() {
  if (timer || typeof window === 'undefined') return
  for (const ev of ['pointerdown', 'keydown', 'wheel', 'touchstart']) window.addEventListener(ev, touch, { passive: true })
  timer = setInterval(() => {
    const c = current?.ctl
    if (c?.accountMode && idleExpired(Date.now(), lastActive)) c.lock()
  }, 30_000)
}

function reset() {
  current?.ctl.dispose()
  current = null
}

if (typeof window !== 'undefined') {
  subscribeAuth(() => {
    if (!isAuthenticated()) reset()
  })
}

export function viewerController(): Promise<ViewerController> {
  if (current) return current.ready
  startIdleWatch()
  touch()
  const ready = getProfile().then(async (p) => {
    const c = new ViewerController(e2eeHttp, p.id, undefined, getAccessToken)
    await c.init()
    return c
  })
  current = { ctl: null as unknown as ViewerController, ready }
  ready.then(
    (c) => {
      if (current?.ready === ready) current.ctl = c
    },
    () => {
      if (current?.ready === ready) current = null
    },
  )
  return ready
}

/** React hook: the shared controller (null while loading) and a re-render tick. */
export function useViewerController(): { ctl: ViewerController | null; tick: number } {
  const [ctl, setCtl] = React.useState<ViewerController | null>(current?.ctl ?? null)
  const [tick, setTick] = React.useState(0)
  React.useEffect(() => {
    let alive = true
    let unsub: (() => void) | null = null
    viewerController()
      .then((c) => {
        if (!alive) return
        unsub = c.subscribe(() => setTick((t) => t + 1))
        setCtl(c)
      })
      .catch(() => undefined)
    return () => {
      alive = false
      unsub?.()
    }
  }, [])
  return { ctl, tick }
}
