#!/usr/bin/env bash
# Orbitly rebrand: idempotent, re-runnable rename of USER-VISIBLE strings.
#
#   scripts/rebrand.sh              apply the rename in the working tree
#   scripts/rebrand.sh --dry-run    list what would change (file:line), change nothing
#   scripts/rebrand.sh --verify     fail (exit 1) if a user-visible "OpenFamily" slipped back in (CI)
#
# What is renamed (only these, nothing else):
#   - the standalone word "OpenFamily" (display name)            -> "Orbitly"
#   - GitHub URLs  TheTractorHacker/openfamily  (not Go imports) -> TheTractorHacker/orbitly
#   - release artifact names  openfamily-<version>.apk|aab|...   -> orbitly-<version>...
#   - brand file names        openfamily-icon|logo|social-card.. -> orbitly-...
# What is NEVER touched (see docs/developers/naming.md): applicationId/bundle id app.openfamily,
# Go module path, DB/role names, compose names, OPENFAMILY_* env vars, X-OpenFamily-* headers,
# openfamily:// scheme, crypto/HKDF labels (lowercase openfamily/...), the Dart package name,
# SQL migrations, vendored packages, NOTICE/LICENSE/credits/history documents.
# A line containing a PROTECT marker (upstream credit, "formerly OpenFamily", "published as OpenFamily", ...) is left alone.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE=apply
case "${1:-}" in
  --dry-run) MODE=dry ;;
  --verify) MODE=verify ;;
  ""|--apply) ;;
  *) echo "usage: $0 [--dry-run|--verify]" >&2; exit 2 ;;
esac
export MODE
exec python3 -I - <<'PY'
import os, re, subprocess, sys

MODE = os.environ['MODE']
# The GitHub repository is still TheTractorHacker/openfamily. Flip to True once the owner has renamed it to
# TheTractorHacker/orbitly; until then links to the old name are correct and are neither rewritten nor flagged.
REPO_RENAMED = False

# Paths (fnmatch-free prefix/suffix rules) that must never be rewritten and are exempt from --verify.
DENY_PREFIX = (
    'NOTICE', 'LICENSE', 'PLAN.md', 'PROGRESS.md', 'WEB_ADMIN_PROGRESS.md',
    'docs/about/credits-and-license.md', 'docs/developers/naming.md', 'docs/CHANGELOG.md',
    'docs/audits/', 'docs/LICENSE_COMPLIANCE.md', 'docs/THIRD_PARTY_LICENSES.md',
    'app/packages/', 'backend/web/dist/', 'backend/web/docs/',   # docs copy is regenerated: docs-check.sh --fix
    'backend/internal/db/migrations/', 'scripts/rebrand.sh', 'scripts/license-check.sh',
    'app/lib/screens/about_screen.dart', 'app/lib/brand.dart', 'web/src/lib/brand.ts',
    'node_modules/', 'web/node_modules/', 'app/build/', 'assets/google-play/tiles/',
    'backend/internal/apkrelease/',   # recognises both the orbitly- and the older openfamily- release file names
)
DENY_SUFFIX = ('package-lock.json', 'go.sum', 'pubspec.lock')
BINARY_EXT = {'.png', '.jpg', '.jpeg', '.gif', '.ico', '.webp', '.jks', '.keystore', '.ttf', '.otf',
              '.woff', '.woff2', '.pdf', '.zip', '.apk', '.aab', '.jar', '.so', '.a', '.age', '.dump', '.gz'}
# Lines containing any of these are credits / historical references and stay verbatim.
PROTECT = re.compile(r'wheresfrank|formerly OpenFamily|Formerly OpenFamily|Based on OpenFamily|based on OpenFamily|'
                     r'fork of OpenFamily|original OpenFamily|published as OpenFamily|called OpenFamily|Was Orbitly called OpenFamily|NexaFlow|rebrand-keep|X-OpenFamily-|OpenFamily_AppStore|'
                     r'before the rename|Yes, OpenFamily|/home/dockhub/OpenFamily')

WORD = re.compile(r'(?<![\w\-/.:@])OpenFamily(?![\w\-]|\.\w)')   # not a hostname like OpenFamily.Example.COM
URL = re.compile(r'TheTractorHacker/openfamily(?!/backend)')
ASSET = re.compile(r'(?<![\w/])openfamily-(?=(?:export|history-|\$V\b|\$\{V\}|\$\{\{|<(?:ver|version|v|tag)[^>]*>|\d|X\.Y|(?:icon|logo|social-card|touch-icon|app-icon)\b))')
# Wording: Orbitly is for any circle of people (family, friends, ...), not families only.
PHRASES = [
    ('self-hosted family location tracker', 'self-hosted location sharing app for your circles'),
    ('self-hosted family location app', 'self-hosted location sharing app for your circles'),
    ('self-hosted family location software', 'self-hosted location sharing software'),
    ('self-hosted family location server', 'self-hosted location sharing server'),
    ('self-hosted family locator', 'self-hosted location sharing'),
    ('family location tracker', 'location sharing app for your circles'),
    ('Join my Orbitly family', 'Join my circle on Orbitly'),
    ('Know where your family is', 'Know where your people are'),
    ('Your location stays in your family, on your own ', 'Your location stays in your circle, on your own '),
    ('Orbitly helps your family see where everyone is and keep ', 'Orbitly helps the people in your circles see where everyone is and keep '),
    ('so your family still sees you when the app is ', 'so your people still see you when the app is '),
    ('Sign in to see your family.', 'Sign in to see your people.'),
    ('Ask your family administrator for', 'Ask your server administrator for'),
    ('Self-hosted family location, in your control.', 'Self-hosted location sharing, in your control.'),
    ('See your family on the live map', 'See your people on the live map'),
    ('so your family can see where you are', 'so the people in your circles can see where you are'),
    ('to show your position on the family map', 'to show your position on the map'),
    ('to send in family chat', 'to send in circle chat'),
    ('unlock your private family location map', 'unlock your private location map'),
    ("Your family\\'s status at a glance", "Your circle\\'s status at a glance"),
    ('to load your family</string>', 'to load your circle</string>'),
]
BRANDDIR = re.compile(r'assets/brand/openfamily/')
BRANDFILE = re.compile(r'(brand/|branding/)openfamily-')

# Documentation-only examples (never applied to code or tests).
DOC_EXT = ('.md', '.html', '.txt', '.example')
DOCRULES = [
    ('openfamily.example.com', 'orbitly.example.com'),
    ('orbitly.git openfamily', 'orbitly.git'),
    ('cd openfamily', 'cd orbitly'),
]
def is_doc(p): return p.endswith(DOC_EXT) or p == 'site/script.js'

def rewrite(line, doc=False):
    if PROTECT.search(line):
        return line
    line = WORD.sub('Orbitly', line)
    if REPO_RENAMED:
        line = URL.sub('TheTractorHacker/orbitly', line)
    line = ASSET.sub('orbitly-', line)
    line = BRANDDIR.sub('assets/brand/', line)
    line = BRANDFILE.sub(r'\1orbitly-', line)
    for a, b in PHRASES:
        line = line.replace(a, b)
    if doc:
        for a, b in DOCRULES:
            line = line.replace(a, b)
    return line

def files():
    out = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
    for p in out:
        if not p or not os.path.isfile(p): continue
        if os.path.splitext(p)[1].lower() in BINARY_EXT: continue
        if p.startswith(DENY_PREFIX) or p.endswith(DENY_SUFFIX): continue
        yield p

hits = 0
for p in files():
    try:
        raw = open(p, 'rb').read()
        if b'\0' in raw: continue
        text = raw.decode('utf-8')
    except (UnicodeDecodeError, OSError):
        continue
    lines = text.split('\n')
    new = [rewrite(l, is_doc(p)) for l in lines]
    if new == lines: continue
    for i, (a, b) in enumerate(zip(lines, new), 1):
        if a != b:
            hits += 1
            if MODE != 'apply': print(f'{p}:{i}: {a.strip()[:140]}')
    if MODE == 'apply':
        open(p, 'w', encoding='utf-8', newline='').write('\n'.join(new))

if MODE == 'verify':
    if hits:
        print(f'\nrebrand verify FAILED: {hits} user-visible OpenFamily string(s) above. Run scripts/rebrand.sh, or add the')
        print('line to the PROTECT list / the file to DENY_PREFIX in scripts/rebrand.sh if the old name is intentional.')
        sys.exit(1)
    print('rebrand verify OK')
elif MODE == 'dry':
    print(f'\n{hits} line(s) would change')
else:
    print(f'rebrand applied: {hits} line(s) changed')
PY
