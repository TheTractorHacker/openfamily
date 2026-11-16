import { test } from 'node:test'
import assert from 'node:assert/strict'
import { placeFromApi, placesFromApi } from '../src/map/placeMapping.ts'
import { mapNoticeText } from '../src/map/mapNotice.ts'

const row = { id: 'p1', family_id: 'f1', family_name: 'Fam', name: 'Home', type: 'home', lat: 1.5, lon: 2.5, radius_meters: 150, address: null }

test('admin place rows map to the camelCase shape the map filters on', () => {
  const p = placeFromApi(row)
  assert.equal(p.familyId, 'f1')
  assert.equal(p.familyName, 'Fam')
  assert.equal(p.radiusMeters, 150)
  assert.equal(p.address, '')
})

test('family place rows take the family name from the caller', () => {
  const p = placeFromApi({ ...row, family_name: undefined, type: '' }, 'Mine')
  assert.equal(p.familyName, 'Mine')
  assert.equal(p.type, 'other')
})

test('bad rows and non-arrays never break the map', () => {
  assert.deepEqual(placesFromApi(null), [])
  assert.deepEqual(placesFromApi({ error: 'x' }), [])
  assert.equal(placesFromApi([row, { ...row, id: 'p2', lat: null, lon: 'x' }]).length, 1)
})

test('notice text exists only for degraded basemaps', () => {
  assert.equal(mapNoticeText('vector'), null)
  assert.equal(mapNoticeText('loading'), null)
  assert.match(mapNoticeText('fallback'), /fallback/)
  assert.match(mapNoticeText('unavailable'), /could not be loaded/)
})
