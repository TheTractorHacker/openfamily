#!/usr/bin/env python3
"""Switch the Apple Watch app target of the Flutter iOS project on or off.

The Watch target (app/ios/OrbitlyWatch, docs/design/WATCH_APPS_APPLE.md) is wired into
app/ios/Runner.xcodeproj/project.pbxproj by hand and has never been built on a Mac
by its author. If it ever breaks the iPhone build, run

    python3 scripts/ios-watch-target.py disable

and commit. It removes every object whose id starts with AB1C0DE0 (all of the Watch
objects use that prefix) plus the shared scheme. The iPhone app is unchanged by this:
Runner/WatchBridge.swift stays and simply finds no watch app.

    python3 scripts/ios-watch-target.py check      # exit 0 when the pbxproj is consistent
    python3 scripts/ios-watch-target.py status     # prints 'enabled' or 'disabled'

Re-enable with `git revert` of the commit that disabled it. Only the Python standard
library is used.
"""
import os
import re
import sys

PREFIX = 'AB1C0DE0'
ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
PBX = os.path.join(ROOT, 'app/ios/Runner.xcodeproj/project.pbxproj')
SCHEME = os.path.join(ROOT, 'app/ios/Runner.xcodeproj/xcshareddata/xcschemes/OrbitlyWatch.xcscheme')


def strip_watch(text: str) -> str:
    out = []
    skip_until = None  # exact closing line of a multi-line object being skipped
    for line in text.split('\n'):
        if skip_until is not None:
            if line == skip_until:
                skip_until = None
            continue
        if PREFIX in line:
            if line.rstrip().endswith('{'):
                indent = line[: len(line) - len(line.lstrip('\t'))]
                skip_until = indent + '};'
            continue
        out.append(line)
    return '\n'.join(out)


def check(text: str) -> list:
    problems = []
    defined = set(re.findall(r'^\t\t([0-9A-F]{24}) ', text, re.M))
    # Every id mentioned anywhere must be defined (or be the project id / a package).
    for m in sorted(set(re.findall(r'\b([0-9A-F]{24})\b', text))):
        if m not in defined and m not in ('97C146E61CF9000F007C117D',):
            # ids defined inside nested blocks (TargetAttributes) are also fine
            if not re.search(r'^\s+' + m + r' = \{', text, re.M):
                problems.append('referenced but not defined: ' + m)
    if text.count('{') != text.count('}'):
        problems.append('unbalanced braces')
    if text.count('(') != text.count(')'):
        problems.append('unbalanced parentheses')
    return problems


def main() -> int:
    cmd = sys.argv[1] if len(sys.argv) > 1 else 'status'
    text = open(PBX, encoding='utf-8').read()
    enabled = PREFIX in text
    if cmd == 'status':
        print('enabled' if enabled else 'disabled')
        return 0
    if cmd == 'check':
        problems = check(text)
        for p in problems:
            print(p)
        print('ok' if not problems else 'FAILED')
        return 1 if problems else 0
    if cmd == 'disable':
        if not enabled:
            print('already disabled')
            return 0
        new = strip_watch(text)
        problems = check(new)
        if problems:
            print('refusing to write, result is inconsistent:', problems)
            return 1
        open(PBX, 'w', encoding='utf-8').write(new)
        if os.path.exists(SCHEME):
            os.remove(SCHEME)
        print('Watch target removed from the Xcode project. Commit app/ios and the scheme removal.')
        return 0
    print(__doc__)
    return 2


if __name__ == '__main__':
    sys.exit(main())
