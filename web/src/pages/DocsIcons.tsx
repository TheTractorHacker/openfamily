import React from 'react'

// Small stroke icons drawn for the Documents page (24x24, currentColor).
const PATHS: Record<string, React.ReactNode> = {
  rocket: <><path d="M5 19c-1 0-2 1-2 2 1 0 2-1 2-2Z" /><path d="M14 4c3 0 6 1 6 1s1 3 1 6c0 4-4 8-8 9l-4-4c1-4 5-8 5-12Z" transform="translate(-2 0)" /><circle cx="14" cy="9" r="1.6" /><path d="M7 14l-3 1 2 2M10 17l-1 3-2-2" /></>,
  users: <><circle cx="9" cy="8" r="3.2" /><path d="M3 20c0-3.5 2.7-6 6-6s6 2.5 6 6" /><circle cx="17" cy="9" r="2.4" /><path d="M16.5 14.2c2.6.3 4.5 2.3 4.5 5.3" /></>,
  server: <><rect x="3" y="4" width="18" height="6" rx="2" /><rect x="3" y="14" width="18" height="6" rx="2" /><path d="M7 7h.01M7 17h.01M11 7h6M11 17h6" /></>,
  wrench: <><path d="M14.5 6.5a4 4 0 0 0 4.9 4.9l-9.8 9.8a2.1 2.1 0 0 1-3-3l9.8-9.8a4 4 0 0 0-1.9-1.9Z" transform="translate(0 -1)" /><path d="M14 5l2.5 2.5 2-2L16 3Z" /></>,
  book: <><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v16H6.5A2.5 2.5 0 0 0 4 21.5Z" /><path d="M4 21.5A2.5 2.5 0 0 1 6.5 19H20M9 8h7" /></>,
  code: <><path d="M8 8l-5 4 5 4M16 8l5 4-5 4M14 5l-4 14" /></>,
  search: <><circle cx="11" cy="11" r="6.5" /><path d="M16 16l5 5" /></>,
  chevron: <path d="M9 6l6 6-6 6" />,
  menu: <path d="M4 7h16M4 12h16M4 17h16" />,
  close: <path d="M6 6l12 12M18 6L6 18" />,
  copy: <><rect x="9" y="9" width="11" height="11" rx="2" /><path d="M5 15V6a2 2 0 0 1 2-2h9" /></>,
  check: <path d="M5 12.5l4.5 4.5L19 7.5" />,
  link: <><path d="M10 14a4 4 0 0 0 5.7 0l3-3a4 4 0 0 0-5.7-5.7l-1 1" /><path d="M14 10a4 4 0 0 0-5.7 0l-3 3a4 4 0 0 0 5.7 5.7l1-1" /></>,
  info: <><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 8h.01" /></>,
  tip: <><path d="M9 18h6M10 21h4" /><path d="M12 3a6 6 0 0 0-3.5 10.9c.6.5 1 1.2 1 2.1h5c0-.9.4-1.6 1-2.1A6 6 0 0 0 12 3Z" /></>,
  warning: <><path d="M12 3.5l9.5 16.5h-19Z" /><path d="M12 10v4.5M12 17.5h.01" /></>,
  important: <><circle cx="12" cy="12" r="9" /><path d="M12 7v6M12 16.5h.01" /></>,
  clock: <><circle cx="12" cy="12" r="9" /><path d="M12 7v5l3 2" /></>,
  file: <><path d="M6 3h8l5 5v13H6Z" /><path d="M14 3v5h5M9 13h6M9 17h6" /></>,
  arrowLeft: <path d="M19 12H5M11 6l-6 6 6 6" />,
  arrowRight: <path d="M5 12h14M13 6l6 6-6 6" />,
  star: <path d="M12 3l2.7 5.6 6.1.8-4.5 4.2 1.1 6-5.4-3-5.4 3 1.1-6L3.2 9.4l6.1-.8Z" />,
  external: <path d="M14 4h6v6M20 4l-9 9M18 14v5a1 1 0 0 1-1 1H5a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h5" />,
  sparkle: <path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8ZM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8Z" />,
}

export function DocIcon({ name, size = 18, className }: { name: string; size?: number; className?: string }) {
  const body = PATHS[name] ?? PATHS.file
  return (
    <svg
      className={className}
      width={size}
      height={size}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {body}
    </svg>
  )
}
