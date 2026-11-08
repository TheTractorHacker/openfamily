// Pure helpers for the Builds page (no React, so node --test can cover them).

import type { BuildAsset, BuildRelease } from './types'

export function formatSize(bytes: number | undefined): string {
  if (!bytes || bytes <= 0 || !Number.isFinite(bytes)) return '—'
  const mb = bytes / (1024 * 1024)
  if (mb >= 1) return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`
  return `${Math.max(1, Math.round(bytes / 1024))} KB`
}

/** Short checksum for a table cell: first 12 characters. */
export function shortSha(sha: string | undefined): string {
  return sha ? sha.slice(0, 12) : ''
}

/** Plain-language CPU label for an Android APK file. */
export function abiLabel(abi: string | undefined): string {
  switch (abi) {
    case 'arm64-v8a':
      return 'Most phones (arm64)'
    case 'armeabi-v7a':
      return 'Older phones (32-bit ARM)'
    case 'x86_64':
      return 'Emulators (x86_64)'
    case 'x86':
      return 'Emulators (x86)'
    case 'universal':
    case undefined:
    case '':
      return 'All phones (universal)'
    default:
      return abi
  }
}

/** Universal first, then arm64, then the rest: the order the server also prefers. */
const ABI_ORDER = ['universal', 'arm64-v8a', 'armeabi-v7a', 'x86_64', 'x86']
export function abiRank(abi: string | undefined): number {
  const i = ABI_ORDER.indexOf(abi || 'universal')
  return i < 0 ? ABI_ORDER.length : i
}

export interface ReleaseSlots {
  androidApks: BuildAsset[]
  aab?: BuildAsset
  wear: BuildAsset[]
  ipa?: BuildAsset
  sbom: BuildAsset[]
  checksums?: BuildAsset
}

/** Sort a release's assets into the slots the page shows. Absent slots stay empty. */
export function releaseSlots(rel: BuildRelease): ReleaseSlots {
  const by = (k: BuildAsset['kind']) => rel.assets.filter((a) => a.kind === k)
  return {
    androidApks: by('android_apk').sort((a, b) => abiRank(a.abi) - abiRank(b.abi)),
    aab: by('android_aab')[0],
    wear: by('wear_apk').sort((a, b) => abiRank(a.abi) - abiRank(b.abi)),
    ipa: by('ios_ipa')[0],
    sbom: by('sbom'),
    checksums: by('checksums')[0],
  }
}

/** Absolute URL to share for an asset: stable server path for the latest, else GitHub's. */
export function shareUrl(origin: string, asset: BuildAsset, latestPath: string | null): string {
  if (latestPath) return origin.replace(/\/$/, '') + latestPath
  return asset.download_url || ''
}

export const IOS_DOC_PATH = 'docs/design/IOS_RELEASE.md'
