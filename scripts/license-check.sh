#!/usr/bin/env bash
# License compliance gate (run in CI). Fails when:
#   - LICENSE is not the AGPL-3.0 text or NOTICE lost the upstream attribution,
#   - the vendored background_locator_2 LICENSE is missing/altered,
#   - a Go module, pub package or production npm package is missing from
#     docs/THIRD_PARTY_LICENSES.md,
#   - a package-lock dependency declares a license outside the allow-list
#     (known exceptions are listed in scripts/license-exceptions.txt).
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 -I - <<'PY'
import json, re, sys
fail = []
def read(p): return open(p, encoding='utf-8').read()

if 'GNU AFFERO GENERAL PUBLIC LICENSE' not in read('LICENSE') or 'Version 3' not in read('LICENSE'):
    fail.append('LICENSE is not AGPL-3.0')
notice = read('NOTICE')
for needle in ('wheresfrank/openfamily', 'background_locator_2', 'AGPL'):
    if needle not in notice: fail.append(f'NOTICE lost required text: {needle}')
bl = read('app/packages/background_locator_2/LICENSE')
for needle in ('REKAB', 'Yukams', 'Permission is hereby granted'):
    if needle not in bl: fail.append(f'background_locator_2/LICENSE missing: {needle}')

inv = read('docs/THIRD_PARTY_LICENSES.md')
def need(kind, name):
    if not re.search(r'^\| ' + re.escape(name) + r' \|', inv, re.M):
        fail.append(f'{kind} {name} missing from docs/THIRD_PARTY_LICENSES.md')

# Go modules (require blocks).
for m in re.finditer(r'^\s*([a-z0-9.\-]+\.[a-z]+/[^\s]+)\s+v[^\s]+', read('backend/go.mod'), re.M):
    need('go module', m.group(1))
# Dart packages (hosted/sdk packages in pubspec.lock; path packages are first party).
for m in re.finditer(r'^  ([a-z0-9_]+):\n(?:    .*\n)*?    source: (\w+)', read('app/pubspec.lock'), re.M):
    if m.group(2) == 'hosted': need('pub package', m.group(1))
# npm production deps and license allow-list.
allowed = {'MIT','ISC','BSD-2-Clause','BSD-3-Clause','Apache-2.0','MPL-2.0','0BSD','CC0-1.0','BlueOak-1.0.0','Unlicense','Python-2.0','(MIT OR Apache-2.0)','MIT-0'}
exceptions = set(l.split('#')[0].strip() for l in read('scripts/license-exceptions.txt').splitlines()) - {''}
lock = json.load(open('web/package-lock.json'))
for k, v in lock['packages'].items():
    if not k: continue
    name = k.split('node_modules/')[-1]
    lic = v.get('license', 'UNKNOWN')
    if lic not in allowed and name not in exceptions:
        fail.append(f'npm {name} has license {lic}, not allowed (add to scripts/license-exceptions.txt only after review)')
    if not v.get('dev') and not v.get('optional'):
        need('npm package', name)

if fail:
    print('license check FAILED:'); [print(' -', f) for f in fail]; sys.exit(1)
print('license check OK')
PY
