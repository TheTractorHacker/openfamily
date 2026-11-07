#!/usr/bin/env python3
"""Orbitly brand source of truth: writes every SVG and Android vector drawable.

Run from the repo root:  python3 assets/brand/generate.py
Rasters (PNG/ICO) are produced from these files by assets/brand/rasterize.sh.

The mark: a central dot (you), an elliptical orbit ring (your circle) with a small
satellite dot (the people around you) sitting in a gap of the ring, and a faint
second ring. It reads as a rounded "O". No fonts: the wordmark is drawn from
round-capped strokes so it renders identically everywhere.
"""
import math, os

OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath(os.path.join(OUT, '..', '..'))

# Palette (contrast against its own background >= 3:1 for graphics, text >= 4.5:1).
CHAR = '#1C1E22'      # charcoal surface
INK = '#111827'       # text on light
PAPER = '#F4F5F7'
THEMES = {
    # name: ring/dot colour, satellite colour, wordmark letters
    'light': dict(ring='#4D7C0F', sat='#0284C7', text=INK),      # on white / paper
    'dark': dict(ring='#A3E635', sat='#38BDF8', text=PAPER),     # on charcoal
}

# ---- geometry of the mark, 256 x 256 box -----------------------------------
C = 128.0
RX, RY, TILT = 104.0, 62.0, -35.0
SW = 16.0            # ring stroke
DOT_R = 30.0
SAT_R = 15.0
GAP_FROM, GAP_TO, SAT_T = -2.0, -46.0, -24.0   # ring parameter angles (degrees)

def ell(t):
    a = math.radians(t)
    return C + RX * math.cos(a), C + RY * math.sin(a)

def f(v): return ('%.2f' % v).rstrip('0').rstrip('.')

P1, P2, SAT = ell(GAP_FROM), ell(GAP_TO), ell(SAT_T)
def ring_d(gap_from, gap_to):
    a, b = ell(gap_from), ell(gap_to)
    return f'M{f(a[0])} {f(a[1])}A{f(RX)} {f(RY)} 0 1 1 {f(b[0])} {f(b[1])}'
RING_D = ring_d(GAP_FROM, GAP_TO)
RING_D_BOLD = ring_d(8.0, -52.0)
FULL_RING_D = (f'M{f(C-RX)} {f(C)}A{f(RX)} {f(RY)} 0 1 1 {f(C+RX)} {f(C)}'
               f'A{f(RX)} {f(RY)} 0 1 1 {f(C-RX)} {f(C)}')

def mark_body(ring, sat, second=True, ring2_opacity=0.5, dot=None):
    dot = dot or ring
    s = ''
    if second:
        s += (f'<path d="{FULL_RING_D}" transform="rotate(35 {f(C)} {f(C)})" fill="none" stroke="{ring}" '
              f'stroke-opacity="{ring2_opacity}" stroke-width="10"/>')
    s += (f'<g transform="rotate({f(TILT)} {f(C)} {f(C)})">'
          f'<path d="{RING_D}" fill="none" stroke="{ring}" stroke-width="{f(SW)}" stroke-linecap="round"/>'
          f'<circle cx="{f(SAT[0])}" cy="{f(SAT[1])}" r="{f(SAT_R)}" fill="{sat}"/></g>'
          f'<circle cx="{f(C)}" cy="{f(C)}" r="{f(DOT_R)}" fill="{dot}"/>')
    return s

def svg(w, h, vb, body, title, desc=None, extra=''):
    d = f'<desc id="d">{desc}</desc>' if desc else ''
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="{vb}" role="img" '
            f'aria-labelledby="t{" d" if desc else ""}"{extra}>\n<title id="t">{title}</title>{d}\n{body}\n</svg>\n')

def write(name, text, folder=OUT):
    p = os.path.join(folder, name)
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'w').write(text)

DESC = 'A central dot inside an orbit ring with a small satellite dot: your people, in orbit.'

# ---- mark variants ----------------------------------------------------------
for theme, c in THEMES.items():
    sfx = '' if theme == 'light' else '-dark'
    write(f'orbitly-mark{sfx}.svg', svg(256, 256, '0 0 256 256', mark_body(c['ring'], c['sat']), 'Orbitly', DESC))
# favicon / small sizes: single ring, thicker, no faint ring, tight crop.
def small_mark(ring, sat):
    return mark_body(ring, sat, second=False)
write('orbitly-mark-mono.svg', svg(256, 256, '0 0 256 256', mark_body('#000000', '#000000', ring2_opacity=0.5), 'Orbitly', DESC))
# On-accent mark (lime tile) for the admin login panel.
write('orbitly-mark-on-accent.svg', svg(256, 256, '0 0 256 256',
      '<rect width="256" height="256" rx="58" fill="#A3E635"/>' + '<g transform="translate(128 128) scale(0.86) translate(-128 -128)">'
      + mark_body(CHAR, '#FFFFFF', ring2_opacity=0.3) + '</g>', 'Orbitly', DESC))

# ---- app icon master (full bleed square, no alpha, 1024) ---------------------
d = THEMES['dark']
def icon_body(scale=0.86):
    return (f'<rect width="256" height="256" fill="{CHAR}"/>'
            f'<g transform="translate(128 128) scale({scale}) translate(-128 -128)">{mark_body(d["ring"], d["sat"])}</g>')
write('orbitly-app-icon.svg', svg(1024, 1024, '0 0 256 256', icon_body(), 'Orbitly app icon', DESC))
# Rounded-tile variant for web/docs/favicons.
tile = (f'<rect width="256" height="256" rx="58" fill="{CHAR}"/>'
        f'<g transform="translate(128 128) scale(0.86) translate(-128 -128)">{mark_body(d["ring"], d["sat"])}</g>')
write('orbitly-icon-tile.svg', svg(256, 256, '0 0 256 256', tile, 'Orbitly', DESC))
# favicon: one thick ring, readable at 16px.
fav = (f'<rect width="256" height="256" rx="58" fill="{CHAR}"/>'
       f'<g transform="translate(128 128) scale(0.95) translate(-128 -128)">'
       + mark_body(d['ring'], d['sat'], second=False).replace(f'stroke-width="{f(SW)}"', 'stroke-width="26"')
       .replace(f'r="{f(SAT_R)}"', 'r="22"').replace(f'r="{f(DOT_R)}"', 'r="36"') + '</g>')
write('favicon.svg', svg(256, 256, '0 0 256 256', fav, 'Orbitly', DESC))

# ---- wordmark (outlined from strokes, no fonts) -----------------------------
# Baseline y=100, x-height top y=40, ascender y=0, stroke 14, round caps.
WS = 14
def wordmark_body(letters, accent, sat):
    L = []
    def stroke(d): L.append(f'<path d="{d}" fill="none" stroke="{letters}" stroke-width="{WS}" stroke-linecap="round" stroke-linejoin="round"/>')
    # o : the orbit ring with a satellite in its gap
    oc = (30, 70); r = 30
    def pt(a): return oc[0] + r * math.cos(math.radians(a)), oc[1] + r * math.sin(math.radians(a))
    a1, a2 = pt(-18), pt(-72)
    stroke(f'M{f(a1[0])} {f(a1[1])}A30 30 0 1 1 {f(a2[0])} {f(a2[1])}')
    s = pt(-45)
    L.append(f'<circle cx="{f(s[0]+3)}" cy="{f(s[1]-3)}" r="8" fill="{sat}"/>')
    L.append(f'<circle cx="30" cy="70" r="9" fill="{accent}"/>')
    stroke('M84 100V40M84 68C84 50 96 40 114 40')                       # r
    stroke('M140 0V100'); stroke('M170 40a30 30 0 1 0 0.01 0')          # b (stem + bowl)
    stroke('M226 40V100'); L.append(f'<circle cx="226" cy="10" r="8" fill="{accent}"/>')   # i
    stroke('M262 12V82Q262 100 280 100H284'); stroke('M248 40H282')    # t
    stroke('M308 0V100')                                                # l
    stroke('M334 40L356 96L378 40'); stroke('M356 96L342 130')          # y
    return ''.join(L)

WM_VB = '-14 -14 408 172'
for theme, c in THEMES.items():
    sfx = '' if theme == 'light' else '-dark'
    write(f'orbitly-wordmark{sfx}.svg', svg(816, 344, WM_VB, wordmark_body(c['text'], c['ring'], c['sat']), 'Orbitly'))

def lockup_h(theme):
    c = THEMES[theme]
    # mark 256 box scaled to 150 tall at left, wordmark (172 tall) scaled 1.0 beside it
    body = (f'<g transform="translate(0 0) scale(0.9)">{mark_body(c["ring"], c["sat"])}</g>'
            f'<g transform="translate(250 56) scale(1.05)">{wordmark_body(c["text"], c["ring"], c["sat"])}</g>')
    return svg(720, 240, '-4 -4 728 248', body, 'Orbitly', DESC)
def lockup_v(theme):
    c = THEMES[theme]
    body = (f'<g transform="translate(112 0)">{mark_body(c["ring"], c["sat"])}</g>'
            f'<g transform="translate(50 300) scale(0.95)">{wordmark_body(c["text"], c["ring"], c["sat"])}</g>')
    return svg(480, 480, '0 0 480 480', body, 'Orbitly', DESC)
for theme in THEMES:
    sfx = '' if theme == 'light' else '-dark'
    write(f'orbitly-logo-horizontal{sfx}.svg', lockup_h(theme))
    write(f'orbitly-logo-vertical{sfx}.svg', lockup_v(theme))

# ---- social card 1280x640 and README banner 1280x320 ------------------------
FONT = 'font-family="Helvetica Neue, Helvetica, Arial, sans-serif"'
def card(w, h, mark, wm_scale, wm_x, wm_y, tag_x, tag_y, tag1, tag2, big):
    c = THEMES['dark']
    ghost = (f'<g opacity="0.10" transform="translate({w-big*0.62:.0f} {h-big*0.78:.0f}) scale({big/256:.3f})">'
             f'{mark_body(c["ring"], c["sat"])}</g>')
    body = (f'<rect width="{w}" height="{h}" fill="{CHAR}"/>{ghost}'
            f'<g transform="translate({tag_x} {(h-mark)/2 - (tag_y_off(h)):.0f}) scale({mark/256:.3f})">{mark_body(c["ring"], c["sat"])}</g>'
            f'<g transform="translate({wm_x} {wm_y}) scale({wm_scale})">{wordmark_body(PAPER, c["ring"], c["sat"])}</g>'
            f'<text x="{tag_x}" y="{tag_y}" {FONT} font-size="{tag1[0]}" font-weight="700" fill="{PAPER}">{tag1[1]}</text>'
            f'<text x="{tag_x}" y="{tag_y + tag2[2]}" {FONT} font-size="{tag2[0]}" fill="#D1D5DB">{tag2[1]}</text>')
    return svg(w, h, f'0 0 {w} {h}', body, 'Orbitly: Your people, in orbit.', None)
def tag_y_off(h): return 70 if h > 400 else 20
T1, T2 = 'Your people, in orbit.', 'Self-hosted location sharing for your circles.'
write('orbitly-social-card.svg', card(1280, 640, 230, 1.3, 372, 160, 96, 470, (56, T1), (32, T2, 56), 760))
write('orbitly-banner.svg', card(1280, 320, 150, 0.85, 272, 70, 96, 262, (34, T1), (22, T2, 34), 380))

# ---- Android vector drawables ------------------------------------------------
def avd_paths(ring, sat, scale, ox, oy, second=True, dot=None, bold=False):
    """VectorDrawable <group> for the mark. scale/offset map the 256 box onto the viewport."""
    dot = dot or ring
    sw, dr, sr = (22, 36, 17) if bold else (SW, DOT_R, SAT_R)
    rd = RING_D_BOLD if bold else RING_D   # bold: survives 24dp status-bar rendering
    sat_c = f'M{f(SAT[0]-sr)} {f(SAT[1])}a{f(sr)} {f(sr)} 0 1 0 {f(2*sr)} 0a{f(sr)} {f(sr)} 0 1 0 {f(-2*sr)} 0z'
    dot_c = f'M{f(C-dr)} {f(C)}a{f(dr)} {f(dr)} 0 1 0 {f(2*dr)} 0a{f(dr)} {f(dr)} 0 1 0 {f(-2*dr)} 0z'
    g = f'    <group android:scaleX="{scale}" android:scaleY="{scale}" android:translateX="{ox}" android:translateY="{oy}">\n'
    if second:
        g += (f'      <group android:rotation="35" android:pivotX="{f(C)}" android:pivotY="{f(C)}">\n'
              f'        <path android:pathData="{FULL_RING_D}" android:fillColor="#00000000" android:strokeColor="{ring}" '
              f'android:strokeAlpha="0.5" android:strokeWidth="10"/>\n      </group>\n')
    g += (f'      <group android:rotation="{f(TILT)}" android:pivotX="{f(C)}" android:pivotY="{f(C)}">\n'
          f'        <path android:pathData="{rd}" android:fillColor="#00000000" android:strokeColor="{ring}" '
          f'android:strokeWidth="{f(sw)}" android:strokeLineCap="round"/>\n'
          f'        <path android:pathData="{sat_c}" android:fillColor="{sat}"/>\n'
          f'      </group>\n'
          f'      <path android:pathData="{dot_c}" android:fillColor="{dot}"/>\n'
          f'    </group>\n')
    return g

def avd(size_dp, viewport, body):
    return (f'<?xml version="1.0" encoding="utf-8"?>\n<vector xmlns:android="http://schemas.android.com/apk/res/android"\n'
            f'    android:width="{size_dp}dp"\n    android:height="{size_dp}dp"\n    android:viewportWidth="{viewport}"\n'
            f'    android:viewportHeight="{viewport}">\n{body}</vector>\n')

RES = os.path.join(ROOT, 'app/android/app/src/main/res')
S = 0.33                      # mark diameter ~ 71dp of the 108dp adaptive layer (safe zone 66dp is the visible circle)
OFF = f(54 - C * S)
write('drawable/ic_launcher_foreground.xml', avd(108, 108, avd_paths(THEMES['dark']['ring'], THEMES['dark']['sat'], S, OFF, OFF)), RES)
write('drawable/ic_launcher_monochrome.xml', avd(108, 108, avd_paths('#FFFFFF', '#FFFFFF', S, OFF, OFF)), RES)
# Notification small icon: white on transparent, single ring + dot + satellite, 24dp.
S24 = 24 / 256 * 1.04
write('drawable/ic_stat_notification.xml', avd(24, 24, avd_paths('#FFFFFF', '#FFFFFF', '%.4f' % S24, '%.2f' % (12 - C * S24), '%.2f' % (12 - C * S24), second=False, bold=True)), RES)
S72 = 0.42                    # launch logo fills the 108dp layer; the layer-list scales it to 72dp
O72 = f(54 - C * S72)
write('drawable/launch_logo.xml', avd(108, 108, avd_paths(THEMES['light']['ring'], THEMES['light']['sat'], S72, O72, O72)), RES)
write('drawable-night/launch_logo.xml', avd(108, 108, avd_paths(THEMES['dark']['ring'], THEMES['dark']['sat'], S72, O72, O72)), RES)
print('brand sources written')
