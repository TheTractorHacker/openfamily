// Shared layout patterns for admin pages — PageHeader, Section, Alert,
// KeyValueList and CopyCommand. Styled in patterns.css with the tokens from
// styles.css; stateless apart from CopyCommand's "Copied" feedback.

import React from 'react'
import './patterns.css'

// ---- PageHeader ----

interface PageHeaderProps {
  title: string
  titleId?: string
  subtitle?: React.ReactNode
  actions?: React.ReactNode
}

export function PageHeader({ title, titleId, subtitle, actions }: PageHeaderProps) {
  return (
    <div className="wb-page-header">
      <div className="wb-page-header-text">
        <h1 id={titleId} className="wb-page-title">
          {title}
        </h1>
        {subtitle && <p className="wb-page-subtitle">{subtitle}</p>}
      </div>
      {actions && <div className="wb-page-actions">{actions}</div>}
    </div>
  )
}

// ---- Section (heading + optional hint/actions + body) ----

interface SectionProps {
  title: string
  description?: React.ReactNode
  actions?: React.ReactNode
  children: React.ReactNode
}

export function Section({ title, description, actions, children }: SectionProps) {
  const id = React.useId()
  return (
    <section className="wb-section" aria-labelledby={id}>
      <div className="wb-section-head">
        <div className="wb-section-head-text">
          <h2 id={id} className="wb-section-title">
            {title}
          </h2>
          {description && <p className="wb-section-desc">{description}</p>}
        </div>
        {actions && <div className="wb-section-actions">{actions}</div>}
      </div>
      {children}
    </section>
  )
}

// ---- Alert (callout) ----

type AlertTone = 'info' | 'success' | 'warning' | 'danger'

interface AlertProps {
  tone?: AlertTone
  title?: string
  children?: React.ReactNode
  /** Optional trailing action (button, link, CopyCommand). */
  action?: React.ReactNode
}

const ALERT_ICON: Record<AlertTone, string> = {
  info: 'M12 11v5m0-8.5h.01M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z',
  success: 'm8 12.5 3 3 5-6M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z',
  warning:
    'M12 9v4m0 3.5h.01M10.3 3.9 2.7 17a2 2 0 0 0 1.7 3h15.2a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0Z',
  danger: 'M12 8v5m0 3.5h.01M12 3a9 9 0 1 0 0 18 9 9 0 0 0 0-18Z',
}

export function Alert({ tone = 'warning', title, children, action }: AlertProps) {
  return (
    <div className={`wb-alert wb-alert-${tone}`} role={tone === 'danger' || tone === 'warning' ? 'alert' : 'status'}>
      <svg className="wb-alert-icon" width="20" height="20" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        <path d={ALERT_ICON[tone]} stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" />
      </svg>
      <div className="wb-alert-body">
        {title && <div className="wb-alert-title">{title}</div>}
        {children && <div className="wb-alert-message">{children}</div>}
        {action && <div className="wb-alert-action">{action}</div>}
      </div>
    </div>
  )
}

// ---- CopyCommand (monospace command with a copy button) ----

export function CopyCommand({ command }: { command: string }) {
  const [copied, setCopied] = React.useState(false)
  React.useEffect(() => {
    if (!copied) return
    const t = window.setTimeout(() => setCopied(false), 1800)
    return () => window.clearTimeout(t)
  }, [copied])
  const copy = () => {
    const done = () => setCopied(true)
    if (navigator.clipboard?.writeText) navigator.clipboard.writeText(command).then(done, () => {})
  }
  return (
    <span className="wb-copycmd">
      <code className="wb-copycmd-text">{command}</code>
      <button type="button" className="wb-copycmd-btn" onClick={copy} aria-label={`Copy command ${command}`}>
        {copied ? 'Copied' : 'Copy'}
      </button>
    </span>
  )
}

// ---- KeyValueList (aligned definition list) ----

export interface KeyValueItem {
  label: string
  value: React.ReactNode
  /** Render the value in the monospace face (versions, IDs, numbers). */
  mono?: boolean
}

export function KeyValueList({ items, label }: { items: KeyValueItem[]; label?: string }) {
  return (
    <dl className="wb-kv" aria-label={label}>
      {items.map((it) => (
        <div key={it.label} className="wb-kv-row">
          <dt className="wb-kv-key">{it.label}</dt>
          <dd className={`wb-kv-value${it.mono ? ' wb-kv-mono' : ''}`}>{it.value}</dd>
        </div>
      ))}
    </dl>
  )
}
