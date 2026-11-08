// Command menu — a top-bar search (⌘K) that filters families and members and
// navigates on selection. Fully keyboard-driven (↑/↓/Enter/Escape), mirroring
// the Vercel/Geist "Search Input + Command Menu" hallmark of a polished admin
// surface.

import React from 'react'
import { listAllMembers, listFamilies } from '../lib/api'
import { routesFor, type RouteDef, type RouteKey } from '../lib/routes'
import { useMe } from '../lib/me'
import type { AdminMember, Family } from '../lib/types'
import { Kbd, Spinner } from './primitives'
import './CommandMenu.css'

interface CommandMenuProps {
  onNavigate: (key: RouteKey) => void
}

type Result =
  | { kind: 'family'; family: Family }
  | { kind: 'member'; member: AdminMember }
  | { kind: 'page'; route: RouteDef }

/** Extra search words so settings topics lead to their page. */
const PAGE_WORDS: Partial<Record<RouteKey, string>> = {
  settings: 'sessions security privacy processing retention notifications sms twilio map style units theme accent integrations dawarich home assistant updates domain account password',
  audit: 'sessions revoke sign out log',
  fleet: 'devices battery permissions push health',
  system: 'backup database migration health',
  builds: 'android apk ios ipa download',
  documents: 'help docs guide manual',
}

export function CommandMenu({ onNavigate }: CommandMenuProps) {
  const { isPlatformAdmin } = useMe()
  const [open, setOpen] = React.useState(false)
  const [query, setQuery] = React.useState('')
  const [families, setFamilies] = React.useState<Family[]>([])
  const [members, setMembers] = React.useState<AdminMember[]>([])
  const [loaded, setLoaded] = React.useState(false)
  const [activeIndex, setActiveIndex] = React.useState(0)
  const inputRef = React.useRef<HTMLInputElement>(null)
  const containerRef = React.useRef<HTMLDivElement>(null)
  const listRef = React.useRef<HTMLDivElement>(null)

  // Lazily load the search corpus on first open.
  React.useEffect(() => {
    if (!open || loaded) return
    let cancelled = false
    Promise.all([listFamilies(), listAllMembers()])
      .then(([f, m]) => {
        if (cancelled) return
        setFamilies(f)
        setMembers(m)
        setLoaded(true)
      })
      .catch(() => {
        if (!cancelled) setLoaded(true)
      })
    return () => {
      cancelled = true
    }
  }, [open, loaded])

  // ⌘K / Ctrl+K focuses the search; Escape closes.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'k') {
        e.preventDefault()
        inputRef.current?.focus()
        setOpen(true)
      } else if (e.key === 'Escape') {
        setOpen(false)
        setQuery('')
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  // Outside click closes.
  React.useEffect(() => {
    if (!open) return
    const onDown = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setOpen(false)
      }
    }
    document.addEventListener('mousedown', onDown)
    return () => document.removeEventListener('mousedown', onDown)
  }, [open])

  const q = query.trim().toLowerCase()
  const filteredFamilies = q
    ? families.filter((f) => f.name.toLowerCase().includes(q))
    : families
  const filteredMembers = q
    ? members.filter((m) => `${m.name} ${m.email}`.toLowerCase().includes(q))
    : members

  const filteredPages = q
    ? routesFor(isPlatformAdmin).filter((r) => `${r.label} ${PAGE_WORDS[r.key] ?? ''}`.toLowerCase().includes(q))
    : []
  const results: Result[] = [
    ...filteredPages.map((route) => ({ kind: 'page' as const, route })),
    ...filteredFamilies.map((family) => ({ kind: 'family' as const, family })),
    ...filteredMembers.map((member) => ({ kind: 'member' as const, member })),
  ]

  // Reset the active index whenever the result set changes.
  React.useEffect(() => {
    setActiveIndex(0)
  }, [q, loaded])

  const select = (r: Result) => {
    onNavigate(r.kind === 'page' ? r.route.key : r.kind === 'family' ? 'families' : 'dashboard')
    setOpen(false)
    setQuery('')
  }

  const onInputKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key === 'ArrowDown') {
      e.preventDefault()
      setActiveIndex((i) => (results.length === 0 ? 0 : Math.min(i + 1, results.length - 1)))
    } else if (e.key === 'ArrowUp') {
      e.preventDefault()
      setActiveIndex((i) => Math.max(i - 1, 0))
    } else if (e.key === 'Enter') {
      e.preventDefault()
      const r = results[activeIndex]
      if (r) select(r)
    }
  }

  // Keep the active item scrolled into view.
  React.useEffect(() => {
    const el = listRef.current?.querySelector<HTMLElement>('[data-active="true"]')
    el?.scrollIntoView({ block: 'nearest' })
  }, [activeIndex])

  const hasFamilies = filteredFamilies.length > 0
  const hasMembers = filteredMembers.length > 0

  return (
    <div className="wb-cmd" ref={containerRef}>
      <div className="wb-cmd-input-wrap">
        <svg width="15" height="15" viewBox="0 0 24 24" fill="none" aria-hidden="true">
          <circle cx="11" cy="11" r="7" stroke="currentColor" strokeWidth="1.8" />
          <path d="m20 20-3.5-3.5" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
        </svg>
        <input
          ref={inputRef}
          className="wb-cmd-input"
          value={query}
          onChange={(e) => {
            setQuery(e.target.value)
            setOpen(true)
          }}
          onFocus={() => setOpen(true)}
          onKeyDown={onInputKeyDown}
          placeholder="Search groups and people…"
          aria-label="Search groups and people"
          role="combobox"
          aria-expanded={open}
          aria-controls="wb-cmd-list"
          aria-activedescendant={results[activeIndex] ? `wb-cmd-opt-${activeIndex}` : undefined}
        />
        <Kbd>⌘K</Kbd>
      </div>

      {open && (
        <div className="wb-cmd-menu" id="wb-cmd-list" role="listbox" ref={listRef}>
          {!loaded ? (
            <div className="wb-cmd-empty">
              <Spinner size={14} /> Loading…
            </div>
          ) : results.length === 0 ? (
            <div className="wb-cmd-empty">No results for “{query}”</div>
          ) : (
            <>
              {filteredPages.length > 0 && <div className="wb-cmd-group">Pages and settings</div>}
              {filteredPages.map((r, i) => (
                <button
                  key={r.key}
                  id={`wb-cmd-opt-${i}`}
                  type="button"
                  className="wb-cmd-item"
                  role="option"
                  aria-selected={activeIndex === i}
                  data-active={activeIndex === i}
                  onMouseEnter={() => setActiveIndex(i)}
                  onClick={() => select({ kind: 'page', route: r })}
                >
                  <span className="wb-cmd-item-name">{r.label}</span>
                  <span className="wb-cmd-item-meta">Page</span>
                </button>
              ))}
              {hasFamilies && <div className="wb-cmd-group">Groups</div>}
              {filteredFamilies.map((f, i) => {
                const idx = filteredPages.length + i
                return (
                  <button
                    key={f.id}
                    id={`wb-cmd-opt-${idx}`}
                    type="button"
                    className="wb-cmd-item"
                    role="option"
                    aria-selected={activeIndex === idx}
                    data-active={activeIndex === idx}
                    onMouseEnter={() => setActiveIndex(idx)}
                    onClick={() => select({ kind: 'family', family: f })}
                  >
                    <span className="wb-cmd-item-name">{f.name}</span>
                    <span className="wb-cmd-item-meta">{f.member_count} members</span>
                  </button>
                )
              })}
              {hasMembers && <div className="wb-cmd-group">Members</div>}
              {filteredMembers.map((m, i) => {
                const idx = filteredPages.length + filteredFamilies.length + i
                return (
                  <button
                    key={m.id}
                    id={`wb-cmd-opt-${idx}`}
                    type="button"
                    className="wb-cmd-item"
                    role="option"
                    aria-selected={activeIndex === idx}
                    data-active={activeIndex === idx}
                    onMouseEnter={() => setActiveIndex(idx)}
                    onClick={() => select({ kind: 'member', member: m })}
                  >
                    <span className="wb-cmd-item-name">{m.name}</span>
                    <span className="wb-cmd-item-meta">{m.family_name}</span>
                  </button>
                )
              })}
            </>
          )}
        </div>
      )}
    </div>
  )
}
