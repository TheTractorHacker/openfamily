// "Private circles: locked / unlocked" for the map header. Shown only when web
// access from any browser is set up (or a browser key is unlocked); a link to
// the Private circles page, where the unlock form lives.

import { useViewerController } from '../lib/privateViewer'
import { Badge, Button } from './primitives'

export function PrivateAccessChip() {
  const { ctl, tick } = useViewerController()
  void tick
  if (!ctl) return null
  const st = ctl.account.status
  const unlocked = !!ctl.unlocked && !!ctl.meta?.registered
  if (!unlocked && !st?.exists) return null
  return (
    <span className="wb-private-chip" data-testid="private-access-chip">
      {unlocked ? (
        <>
          <Badge tone="green" dot>Private circles unlocked</Badge>
          {ctl.accountMode && (
            <Button size="sm" variant="ghost" onClick={() => ctl.lock()}>
              Lock
            </Button>
          )}
        </>
      ) : (
        <a href="#/private" className="wb-private-chip-link">
          <Badge tone="orange" dot>Private circles locked</Badge> Unlock
        </a>
      )}
    </span>
  )
}
