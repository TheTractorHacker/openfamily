import { useThemePreference, type ThemePreference } from '../lib/theme'

const ORDER: ThemePreference[] = ['system', 'light', 'dark']
const LABEL: Record<ThemePreference, string> = {
  system: 'System theme',
  light: 'Light theme',
  dark: 'Dark theme',
}

/** One-tap appearance switch (System → Light → Dark) for the top bar and sign-in page. */
export function ThemeCycleButton({ className }: { className?: string }) {
  const [preference, setPreference] = useThemePreference()
  const next = ORDER[(ORDER.indexOf(preference) + 1) % ORDER.length]

  return (
    <button
      type="button"
      className={`wb-theme-cycle${className ? ` ${className}` : ''}`}
      onClick={() => setPreference(next)}
      aria-label={`${LABEL[preference]}. Switch to ${LABEL[next].toLowerCase()}`}
      title={`${LABEL[preference]} (click for ${LABEL[next].toLowerCase()})`}
    >
      <svg width="18" height="18" viewBox="0 0 24 24" fill="none" aria-hidden="true">
        {preference === 'light' && (
          <>
            <circle cx="12" cy="12" r="4" stroke="currentColor" strokeWidth="1.8" />
            <path
              d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"
              stroke="currentColor"
              strokeWidth="1.8"
              strokeLinecap="round"
            />
          </>
        )}
        {preference === 'dark' && (
          <path
            d="M20 14.5A8 8 0 0 1 9.5 4a8 8 0 1 0 10.5 10.5Z"
            stroke="currentColor"
            strokeWidth="1.8"
            strokeLinejoin="round"
          />
        )}
        {preference === 'system' && (
          <>
            <rect x="3" y="4" width="18" height="12" rx="2" stroke="currentColor" strokeWidth="1.8" />
            <path d="M8 20h8M12 16v4" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" />
          </>
        )}
      </svg>
    </button>
  )
}
