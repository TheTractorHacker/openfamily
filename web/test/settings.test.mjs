// Settings section routing (one URL per page) and the unsaved-changes guard.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  SETTINGS_PAGES,
  defaultSettingsPage,
  settingsHash,
  settingsPageFromHash,
  settingsPagesFor,
} from '../src/lib/settingsPages.ts'
import { confirmLeave, leaveMessage, setUnsaved, unsavedLabels } from '../src/lib/unsaved.ts'

test('every settings page has a unique key, label and description', () => {
  const keys = SETTINGS_PAGES.map((p) => p.key)
  assert.equal(new Set(keys).size, keys.length)
  for (const p of SETTINGS_PAGES) {
    assert.ok(p.label && p.description, p.key)
  }
})

test('admins see every page; regular users only the personal ones', () => {
  assert.equal(settingsPagesFor(true).length, SETTINGS_PAGES.length)
  const user = settingsPagesFor(false).map((p) => p.key)
  assert.deepEqual(user.sort(), ['account', 'appearance', 'integrations', 'updates'])
  for (const k of ['general', 'security', 'backups', 'notifications', 'privacy', 'server']) {
    assert.ok(!user.includes(k), k)
  }
})

test('deep links resolve to their page', () => {
  assert.deepEqual(settingsPageFromHash('#/settings/backups', true), { page: 'backups', redirect: false })
  assert.deepEqual(settingsPageFromHash('#/settings/security?x=1', true), { page: 'security', redirect: false })
  assert.equal(settingsHash('notifications'), '#/settings/notifications')
})

test('bare, unknown and forbidden settings URLs redirect to the default page', () => {
  assert.deepEqual(settingsPageFromHash('#/settings', true), { page: 'general', redirect: true })
  assert.deepEqual(settingsPageFromHash('#/settings', false), { page: 'account', redirect: true })
  assert.deepEqual(settingsPageFromHash('#/settings/nope', true), { page: 'general', redirect: true })
  assert.deepEqual(settingsPageFromHash('#/settings/backups', false), { page: 'account', redirect: true })
  // Old single-page section name.
  assert.deepEqual(settingsPageFromHash('#/settings/data', true), { page: 'backups', redirect: true })
  assert.equal(defaultSettingsPage(true), 'general')
})

test('non-settings URLs are not claimed', () => {
  assert.equal(settingsPageFromHash('#/system', true), null)
  assert.equal(settingsPageFromHash('#/settingsx', true), null)
})

test('leaving with unsaved changes asks, and cancelling keeps the changes', () => {
  assert.equal(confirmLeave(() => assert.fail('must not ask when nothing is dirty')), true)
  setUnsaved(101, 'Sign-in sessions')
  setUnsaved(102, 'Map style')
  let asked = ''
  assert.equal(
    confirmLeave((m) => {
      asked = m
      return false
    }),
    false,
  )
  assert.match(asked, /Sign-in sessions/)
  assert.match(asked, /Map style/)
  assert.deepEqual(unsavedLabels(), ['Sign-in sessions', 'Map style'])
  assert.equal(confirmLeave(() => true), true)
  assert.deepEqual(unsavedLabels(), [])
})

test('a saved form clears its entry', () => {
  setUnsaved(201, 'Backup settings')
  setUnsaved(201, null)
  assert.deepEqual(unsavedLabels(), [])
  assert.equal(leaveMessage(['A', 'A']), 'You have unsaved changes in “A”. Leave this page and discard them?')
})
