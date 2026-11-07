import { BRAND_NAME, REPO_URL, UPSTREAM_NAME, UPSTREAM_URL } from '../lib/brand'

/**
 * Credit and source offer shown in the admin footer and on the login page:
 * AGPL-3.0 section 13 asks network users to be able to reach the source, and
 * the upstream project keeps its credit.
 */
export function AboutFooter({ version }: { version?: string | null }) {
  return (
    <details className="wb-about-footer">
      <summary>
        <span className="wb-about-short" aria-hidden="true">i</span>
        <span className="wb-about-title">
          {BRAND_NAME}
          {version ? ` ${version}` : ''} · About
        </span>
      </summary>
      <div className="wb-about-body">
      <div>
        {BRAND_NAME}
        {version ? ` ${version}` : ''}
      </div>
      <div>
        Based on{' '}
        <a href={UPSTREAM_URL} target="_blank" rel="noopener noreferrer">
          {UPSTREAM_NAME}
        </a>{' '}
        by wheresfrank and contributors (AGPL-3.0)
      </div>
      <div>
        <a href={REPO_URL} target="_blank" rel="noopener noreferrer">Source code</a>
      </div>
      </div>
    </details>
  )
}
