// Unsaved-changes registry for the admin web.
//
// Forms call useUnsavedChanges(dirty, label). While anything is dirty:
// - closing or reloading the tab asks the browser's own "Leave site?" prompt;
// - in-app navigation (sidebar, settings sub-navigation, browser Back/Forward)
//   asks confirmLeave() first and stays put when the user cancels.
// The registry is plain module state so non-React code (the hash router) can
// read it; entries are removed when a form saves, discards or unmounts.

import React from 'react'

const entries = new Map<number, string>()
let nextId = 1
const listeners = new Set<() => void>()

function emit() {
  listeners.forEach((l) => l())
}

function onBeforeUnload(event: BeforeUnloadEvent) {
  if (entries.size === 0) return
  event.preventDefault()
  // Chrome needs returnValue set; the text itself is ignored by browsers.
  event.returnValue = ''
}

let unloadBound = false
function syncUnload() {
  if (typeof window === 'undefined') return
  if (entries.size > 0 && !unloadBound) {
    window.addEventListener('beforeunload', onBeforeUnload)
    unloadBound = true
  } else if (entries.size === 0 && unloadBound) {
    window.removeEventListener('beforeunload', onBeforeUnload)
    unloadBound = false
  }
}

/** Marks (or clears) one dirty form. Returns a release function. */
export function setUnsaved(id: number, label: string | null): void {
  if (label === null) entries.delete(id)
  else entries.set(id, label)
  syncUnload()
  emit()
}

/** Labels of every form with unsaved changes, in registration order. */
export function unsavedLabels(): string[] {
  return Array.from(entries.values())
}

/** Builds the confirmation text for the given labels (exported for tests). */
export function leaveMessage(labels: string[]): string {
  const list = Array.from(new Set(labels))
  const what = list.length === 1 ? `“${list[0]}”` : list.map((l) => `“${l}”`).join(', ')
  return `You have unsaved changes in ${what}. Leave this page and discard them?`
}

/**
 * Asks before leaving when something is unsaved. Returns true when it is fine
 * to navigate (nothing dirty, or the user agreed to discard). `ask` is the
 * prompt function, injectable for tests.
 */
export function confirmLeave(ask: (msg: string) => boolean = (m) => window.confirm(m)): boolean {
  if (entries.size === 0) return true
  const ok = ask(leaveMessage(unsavedLabels()))
  if (ok) {
    entries.clear()
    syncUnload()
    emit()
  }
  return ok
}

export function subscribeUnsaved(fn: () => void): () => void {
  listeners.add(fn)
  return () => {
    listeners.delete(fn)
  }
}

/** Registers a form's dirty state for as long as the component is mounted. */
export function useUnsavedChanges(dirty: boolean, label: string): void {
  const idRef = React.useRef(0)
  if (idRef.current === 0) idRef.current = nextId++
  React.useEffect(() => {
    const id = idRef.current
    setUnsaved(id, dirty ? label : null)
    return () => setUnsaved(id, null)
  }, [dirty, label])
}

/** True while any form has unsaved changes (re-renders on change). */
export function useHasUnsaved(): boolean {
  return React.useSyncExternalStore(
    subscribeUnsaved,
    () => entries.size > 0,
    () => false,
  )
}
