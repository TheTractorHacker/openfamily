#!/usr/bin/env python3
"""Wear OS icons from the brand drawables.

The phone app's launcher drawables are written by assets/brand/generate.py from
assets/brand/orbitly-mark.svg. This script reuses them (so the watch can never
drift from the brand source) and derives the two extra drawables the watch needs:

  ic_launcher_foreground / ic_launcher_monochrome  copied as is (adaptive icon)
  ic_complication                                  24dp white mark, larger scale
  tile_preview                                     tile picker preview

Run from the repo root:  python3 wear/tools/gen_icons.py
"""
import os, re, shutil

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
SRC = os.path.join(ROOT, 'app/android/app/src/main/res/drawable')
DST = os.path.join(ROOT, 'wear/app/src/main/res/drawable')
os.makedirs(DST, exist_ok=True)

for n in ('ic_launcher_foreground.xml', 'ic_launcher_monochrome.xml'):
    shutil.copyfile(os.path.join(SRC, n), os.path.join(DST, n))

mono = open(os.path.join(SRC, 'ic_launcher_monochrome.xml')).read()

# Complication icon: same geometry on a 24dp canvas, the mark filling ~88% of it.
comp = mono.replace('android:width="108dp"', 'android:width="24dp"').replace('android:height="108dp"', 'android:height="24dp"')
comp = re.sub(r'<group android:scaleX="[^"]+" android:scaleY="[^"]+" android:translateX="[^"]+" android:translateY="[^"]+">',
              '<group android:scaleX="0.4" android:scaleY="0.4" android:translateX="2.8" android:translateY="2.8">', comp, count=1)
comp = comp.replace('android:viewportWidth="108"', 'android:viewportWidth="108"').replace('android:viewportHeight="108"', 'android:viewportHeight="108"')
# viewport stays 108: scale maps the 256 box (x 0.4 = 102) onto it, then the vector scales to 24dp.
comp = re.sub(r'android:scaleX="0.4" android:scaleY="0.4" android:translateX="2.8" android:translateY="2.8"',
              'android:scaleX="0.4" android:scaleY="0.4" android:translateX="2.8" android:translateY="2.8"', comp)
open(os.path.join(DST, 'ic_complication.xml'), 'w').write(comp)

fg = open(os.path.join(SRC, 'ic_launcher_foreground.xml')).read()
body = fg.split('android:viewportHeight="108">\n', 1)[1].rsplit('</vector>', 1)[0]
open(os.path.join(DST, 'tile_preview.xml'), 'w').write(
    '<?xml version="1.0" encoding="utf-8"?>\n'
    '<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '    android:width="108dp"\n    android:height="108dp"\n    android:viewportWidth="108"\n    android:viewportHeight="108">\n'
    '    <path android:pathData="M0 0h108v108h-108z" android:fillColor="#1C1E22"/>\n' + body + '</vector>\n')
print('wear icons written')
