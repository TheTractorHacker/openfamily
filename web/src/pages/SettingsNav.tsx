// Settings sub-navigation: jump links with scroll-spy and a search box that
// hides sections (and cards) that do not match.

import React from 'react'

const SECTIONS: [string, string][] = [
  ['general', 'General'], ['privacy', 'Privacy & processing'], ['security', 'Security'],
  ['notifications', 'Notifications'], ['data', 'Data & retention'], ['integrations', 'Integrations'],
  ['appearance', 'Appearance'], ['updates', 'Updates & about'],
]

export function SettingsSection({ id, title, admin, children }: { id: string; title: string; admin: boolean; children: React.ReactNode }) {
  const kids = React.Children.toArray(children).filter(Boolean)
  if (!admin || kids.length === 0) return null
  return (
    <section id={`settings-${id}`} data-settings-section={id} className="wb-settings-sec" aria-labelledby={`settings-${id}-h`}>
      <h2 id={`settings-${id}-h`} className="wb-settings-sec-title">{title}</h2>
      {kids}
    </section>
  )
}

export function useSettingsNav(rootRef: React.RefObject<HTMLElement>) {
  const [query, setQuery] = React.useState('')
  const [active, setActive] = React.useState('general')
  const [empty, setEmpty] = React.useState(false)

  React.useEffect(() => {
    const root = rootRef.current
    if (!root) return
    const q = query.trim().toLowerCase()
    let any = false
    root.querySelectorAll<HTMLElement>('[data-settings-section]').forEach((sec) => {
      const cards = Array.from(sec.children).filter((c) => c.tagName !== 'H2') as HTMLElement[]
      let shown = 0
      cards.forEach((c) => {
        const match = !q || (c.textContent ?? '').toLowerCase().includes(q) || (sec.getAttribute('data-settings-section') ?? '').includes(q)
        c.hidden = !match
        if (match) shown++
      })
      sec.hidden = shown === 0
      if (shown > 0) any = true
    })
    setEmpty(!any)
  }, [query, rootRef])

  React.useEffect(() => {
    const root = rootRef.current
    if (!root || typeof IntersectionObserver === 'undefined') return
    const scroller = root.closest('.wb-shell-content')
    const io = new IntersectionObserver(
      (entries) => {
        const vis = entries.filter((e) => e.isIntersecting).sort((a, b) => a.boundingClientRect.top - b.boundingClientRect.top)[0]
        if (vis) setActive((vis.target as HTMLElement).dataset.settingsSection ?? 'general')
      },
      { root: scroller, rootMargin: '0px 0px -70% 0px', threshold: 0 },
    )
    root.querySelectorAll('[data-settings-section]').forEach((el) => io.observe(el))
    return () => io.disconnect()
  }, [rootRef])

  return { query, setQuery, active, empty }
}

export function SettingsNav({ nav }: { nav: ReturnType<typeof useSettingsNav> }) {
  const jump = (id: string) => {
    const el = document.getElementById(`settings-${id}`)
    if (!el) return
    const reduce = window.matchMedia?.('(prefers-reduced-motion: reduce)').matches
    el.scrollIntoView({ behavior: reduce ? 'auto' : 'smooth', block: 'start' })
  }
  return (
    <div className="wb-settings-nav">
      <input className="wb-input wb-settings-search" type="search" placeholder="Search settings…" aria-label="Search settings"
        value={nav.query} onChange={(e) => nav.setQuery(e.target.value)} />
      <nav aria-label="Settings sections" className="wb-settings-jump">
        {SECTIONS.map(([id, label]) => (
          <button key={id} type="button" className={`wb-settings-chip${nav.active === id ? ' is-on' : ''}`}
            aria-current={nav.active === id ? 'true' : undefined} onClick={() => jump(id)}>
            {label}
          </button>
        ))}
      </nav>
      {nav.empty && <p className="wb-help" role="status">No settings match “{nav.query}”.</p>}
    </div>
  )
}
