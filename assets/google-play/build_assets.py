"""Package genuine Flutter captures and existing branding for Google Play.

Run the Flutter capture test first, then run this script with Pillow installed.
"""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageFilter

ROOT = Path(__file__).resolve().parent
BRAND = ROOT.parent / 'brand' / 'openfamily'
OUT = ROOT / 'upload'
OUT.mkdir(exist_ok=True)
INK, LIME, WHITE, MUTED = '#1C1E22', '#A3E635', '#F4F5F7', '#B7C2CF'
FONT = Path('/System/Library/Fonts/Supplemental')
def font(size, bold=False):
    return ImageFont.truetype(str(FONT / ('Arial Bold.ttf' if bold else 'Arial.ttf')), size)

def canvas(w, h):
    im = Image.new('RGB', (w, h), INK)
    d = ImageDraw.Draw(im)
    for x in range(12, w, 28):
        for y in range(12, h, 28):
            d.ellipse((x, y, x+2, y+2), fill='#30343A')
    return im

icon = Image.open(BRAND / 'openfamily-app-icon.png').convert('RGBA')
# Google applies the corner mask; flatten the existing transparent corners.
square = Image.new('RGBA', icon.size, INK)
square.alpha_composite(icon)
square.resize((512,512), Image.Resampling.LANCZOS).save(OUT / 'icon-512.png')

specs = [
    ('01-server', 'Made for your server.', 'Server setup required', 'Connect using your family’s server address.'),
    ('02-people', 'Your people, together.', 'Family at a glance', 'See shared places, battery levels and activity.'),
    ('03-places', 'Everyday places.', 'Arrival and departure alerts', 'Save home, school, work and more.'),
    ('04-invite', 'Bring the family along.', 'Join with an invitation', 'One server. A shared space for your family.'),
]
for idx, (name, title, label, subtitle) in enumerate(specs, 1):
    im = canvas(1080,1920)
    d = ImageDraw.Draw(im)
    d.text((72,55), 'OPENFAMILY', font=font(25,True), fill=LIME)
    d.text((72,111), title, font=font(64,True), fill=WHITE)
    d.text((72,197), subtitle, font=font(31), fill=MUTED)
    shot = Image.open(ROOT / 'raw' / f'{name}.png').convert('RGB').resize((900,1500),Image.Resampling.LANCZOS)
    mask = Image.new('L',shot.size,0)
    ImageDraw.Draw(mask).rounded_rectangle((0,0,899,1499),radius=24,fill=255)
    im.paste(shot,(90,289),mask)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((72,1817,952,1879),radius=15,fill=LIME if idx==1 else '#2A2D33')
    d.text((96,1830),label,font=font(29,True),fill=INK if idx==1 else WHITE)
    d.text((990,1840),f'0{idx}',font=font(24),fill=MUTED,anchor='mm')
    im.save(OUT / f'{name}.png',optimize=True)

# Map screenshot uses the actual MapScreen with fictional Central Park pins.
mapshot=Image.open(ROOT/'raw'/'05-map.png').convert('RGB').resize((900,1500),Image.Resampling.LANCZOS)
im=canvas(1080,1920)
d=ImageDraw.Draw(im)
d.text((72,55),'OPENFAMILY',font=font(25,True),fill=LIME)
d.text((72,111),'Your family, on the map.',font=font(64,True),fill=WHITE)
d.text((72,197),'See shared locations at a glance.',font=font(31),fill=MUTED)
mask=Image.new('L',mapshot.size,0)
ImageDraw.Draw(mask).rounded_rectangle((0,0,899,1499),radius=24,fill=255)
im.paste(mapshot,(90,289),mask)
d=ImageDraw.Draw(im)
d.rounded_rectangle((72,1817,952,1879),radius=15,fill='#2A2D33')
d.text((96,1830),'Live family map',font=font(29,True),fill=WHITE)
d.text((990,1840),'02',font=font(24),fill=MUTED,anchor='mm')
d.text((966,1753),'© OpenStreetMap contributors',font=font(20),fill=INK,anchor='ra',stroke_width=3,stroke_fill='#F8FAFC')
im.save(OUT/'05-map.png',optimize=True)

im=canvas(1024,500)
d=ImageDraw.Draw(im)
d.text((64,59),'OPENFAMILY',font=font(21,True),fill=LIME)
d.text((64,111),'Family location',font=font(53,True),fill=WHITE)
d.text((64,173),'sharing. Hosted',font=font(53,True),fill=WHITE)
d.text((64,235),'by you.',font=font(53,True),fill=WHITE)
d.text((64,322),'Stay connected on your own terms.',font=font(23),fill=MUTED)
d.rounded_rectangle((64,377,487,427),radius=12,fill=LIME)
d.text((82,389),'Self-hosted server required',font=font(25,True),fill=INK)
shot=Image.open(ROOT / 'raw' / '05-map.png').convert('RGB').resize((294,490),Image.Resampling.LANCZOS)
im.paste(shot,(670,56))
d=ImageDraw.Draw(im)
d.text((960,478),'© OpenStreetMap contributors',font=font(13),fill=INK,anchor='ra',stroke_width=2,stroke_fill='#F8FAFC')
im.save(OUT/'feature-map-1024x500.png',optimize=True)

thumbs=[]
for name,*_ in specs:
    thumbs.append(Image.open(OUT/f'{name}.png').resize((270,480)))
preview=Image.new('RGB',(1080,480),INK)
for idx,t in enumerate(thumbs): preview.paste(t,(idx*270,0))
preview.save(ROOT/'screenshots-preview.jpg',quality=92)
for p in OUT.glob('*.png'):
    with Image.open(p) as asset:
        print(f'{p.name}: {asset.size}, {p.stat().st_size:,} bytes')
