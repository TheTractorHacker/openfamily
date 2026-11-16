// Catches a crash (or a failed lazy chunk) in one page so the shell stays usable and the person sees
// what happened with a way to retry, instead of a silent blank content area.

import React from 'react'
import { ErrorState } from './primitives'

interface Props {
  /** Changes when the route changes so a crashed page does not keep the next page in the error state. */
  resetKey: string
  children: React.ReactNode
}

interface State {
  error: Error | null
}

export class RouteErrorBoundary extends React.Component<Props, State> {
  state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  componentDidUpdate(prev: Props): void {
    if (prev.resetKey !== this.props.resetKey && this.state.error) this.setState({ error: null })
  }

  render(): React.ReactNode {
    if (!this.state.error) return this.props.children
    return (
      <div className="wb-page">
        <ErrorState
          title="This page failed to load"
          description={`${this.state.error.message || 'Unexpected error'}. If the problem persists after reloading, the browser may be running an outdated copy of the panel.`}
          onRetry={() => window.location.reload()}
        />
      </div>
    )
  }
}
