#!/usr/bin/env python3
"""Compose the store listing images (used by scripts/store-assets.sh).

Input : <raw>/<slot>__<screen>.png (plain screen renders from the Flutter test),
        <raw>/manifest.json (slot sizes and captions), <raw>/Roboto-Bold.ttf,
        optional <watch>/wear-*.png and <watch>/applewatch-*.png real captures.
Output: <out>/google-play/..., <out>/app-store/..., <out>/README.md
Needs Pillow only.
"""
import argparse
import glob
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

BG_TOP = (28, 30, 34)       # #1C1E22 brand dark
BG_BOTTOM = (22, 44, 58)
LIME = (163, 230, 53)       # #A3E635
SKY = (56, 189, 248)        # #38BDF8
WHITE = (255, 255, 255)

# Which output folder each rendered slot goes to.
SLOT_DIRS = {
    "play-phone": "google-play/phone",
    "play-tablet7": "google-play/tablet-7in",
    "play-tablet10": "google-play/tablet-10in",
    "play-foldable": "google-play/foldable-inner-screen",
    "ios-iphone-6.9": "app-store/iphone-6.9in-1320x2868",
    "ios-iphone-6.5": "app-store/iphone-6.5in-1284x2778",
    "ios-ipad-13": "app-store/ipad-13in-2064x2752",
}


def gradient(w, h):
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(1, h - 1)
        col.putpixel((0, y), tuple(round(BG_TOP[i] + (BG_BOTTOM[i] - BG_TOP[i]) * t) for i in range(3)))
    return col.resize((w, h), Image.NEAREST)


def wrap(draw, text, font, max_w):
    words, lines, cur = text.split(), [], ""
    for w in words:
        t = (cur + " " + w).strip()
        if draw.textlength(t, font=font) <= max_w or not cur:
            cur = t
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    return lines


def rounded(img, radius):
    mask = Image.new("L", img.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, img.size[0] - 1, img.size[1] - 1), radius, fill=255)
    out = Image.new("RGBA", img.size)
    out.paste(img.convert("RGBA"), (0, 0), mask)
    return out


def compose(slot, raw_png, caption, font_path):
    w, h, m, ch = slot["w"], slot["h"], slot["margin"], slot["caption_height"]
    canvas = gradient(w, h)
    d = ImageDraw.Draw(canvas)
    size = int(ch * 0.30)
    font = ImageFont.truetype(font_path, size)
    lines = wrap(d, caption, font, w - 2 * m)
    while len(lines) > 2 and size > 12:
        size -= 2
        font = ImageFont.truetype(font_path, size)
        lines = wrap(d, caption, font, w - 2 * m)
    line_h = int(size * 1.2)
    y = (ch - line_h * len(lines)) // 2 + int(m * 0.2)
    for ln in lines:
        d.text(((w - d.textlength(ln, font=font)) / 2, y), ln, font=font, fill=WHITE)
        y += line_h
    d.rounded_rectangle((w // 2 - m, ch - int(m * 0.35), w // 2 + m, ch - int(m * 0.35) + 6), 3, fill=LIME)
    shot = Image.open(raw_png).convert("RGB")
    inner_w, inner_h = w - 2 * m, h - ch - m
    if shot.size != (inner_w, inner_h):
        shot = shot.resize((inner_w, inner_h), Image.LANCZOS)
    frame = rounded(shot, int(m * 0.9))
    canvas.paste(frame, (m, ch), frame)
    return canvas.convert("RGB")  # no alpha: App Store rejects transparency


def feature_graphic(brand, raw, font_path, out_path):
    w, h = 1024, 500
    img = gradient(w, h)
    d = ImageDraw.Draw(img)
    big = ImageFont.truetype(font_path, 84)
    mid = ImageFont.truetype(font_path, 34)
    mark_path = os.path.join(brand, "orbitly-mark-dark.png")
    x = 64
    if os.path.exists(mark_path):
        mark = Image.open(mark_path).convert("RGBA").resize((120, 120), Image.LANCZOS)
        img.paste(mark, (x, 150), mark)
    d.text((x + 150, 150), "Orbitly", font=big, fill=WHITE)
    d.text((x, 290), "Your people, in orbit.", font=mid, fill=LIME)
    d.text((x, 340), "Private location sharing for", font=mid, fill=WHITE)
    d.text((x, 382), "family and friends. Your own server.", font=mid, fill=WHITE)
    shot_path = os.path.join(raw, "play-phone__people.png")
    if os.path.exists(shot_path):
        s = Image.open(shot_path).convert("RGB")
        sh = 420
        sw = round(s.size[0] * sh / s.size[1])
        s = rounded(s.resize((sw, sh), Image.LANCZOS), 28)
        img.paste(s, (w - sw - 70, 90), s)
    img.save(out_path, optimize=True)


def watch_images(watch_dir, out, notes):
    if not os.path.isdir(watch_dir):
        notes.append("No real watch captures found in raw-watch/: Wear OS and Apple Watch screenshots were NOT produced (see docs/release/STORE_ASSETS.md for the capture commands).")
        return
    for f in sorted(glob.glob(os.path.join(watch_dir, "wear-*.png"))):
        im = Image.open(f).convert("RGB")
        side = min(im.size)
        l, t = (im.size[0] - side) // 2, (im.size[1] - side) // 2
        im = im.crop((l, t, l + side, t + side)).resize((512, 512), Image.LANCZOS)
        dest = os.path.join(out, "google-play/wear-os-512x512")
        os.makedirs(dest, exist_ok=True)
        im.save(os.path.join(dest, os.path.basename(f)), optimize=True)
        notes.append(f"Wear OS: {os.path.basename(f)} cropped to a centred square and scaled to 512x512 (Play: 1:1, at least 384).")
    for f in sorted(glob.glob(os.path.join(watch_dir, "applewatch-*.png"))):
        im = Image.open(f).convert("RGB")
        tw, th = 416, 496
        scale = min(tw / im.size[0], th / im.size[1])
        r = im.resize((round(im.size[0] * scale), round(im.size[1] * scale)), Image.LANCZOS)
        canvas = Image.new("RGB", (tw, th), (0, 0, 0))
        canvas.paste(r, ((tw - r.size[0]) // 2, (th - r.size[1]) // 2))
        dest = os.path.join(out, "app-store/apple-watch-416x496")
        os.makedirs(dest, exist_ok=True)
        canvas.save(os.path.join(dest, os.path.basename(f)), optimize=True)
        notes.append(f"Apple Watch: {os.path.basename(f)} fitted into 416x496 (Series 10/11 46 mm). Capture at the exact size for each model you target.")


README = """# Store assets (generated)

Generated by `scripts/store-assets.sh` on {when}. Do not commit this folder.

**These images are RENDERS of the real Orbitly widget tree** (the same screens the
app shows), drawn on a computer with the Roboto font, fictional "Rivera Family" data
and no map tiles. They are not captures from a phone. Apple and Google require
screenshots that show the real app: capture the final set once on a real device or
emulator (commands in docs/release/STORE_ASSETS.md) and use these as the layout
reference or as a fallback only.

## Where to upload

| Folder | Upload to |
|---|---|
| google-play/phone/ | Play Console, Store listing, Phone screenshots (1080x1920, 9:16, min 2, max 8) |
| google-play/tablet-7in/ | Play Console, 7-inch tablet screenshots (1200x1920) |
| google-play/tablet-10in/ | Play Console, 10-inch tablet screenshots (1600x2560) |
| google-play/foldable-inner-screen/ | Play Console, large-screen / foldable (1840x2208) |
| google-play/feature-graphic-1024x500.png | Play Console, Feature graphic |
| google-play/icon-512.png | Play Console, App icon (512x512, 32-bit PNG) |
| google-play/wear-os-512x512/ | Play Console, Wear OS screenshots (only from real captures) |
| app-store/iphone-6.9in-1320x2868/ | App Store Connect, iPhone 6.9" display |
| app-store/iphone-6.5in-1284x2778/ | App Store Connect, iPhone 6.5" display |
| app-store/ipad-13in-2064x2752/ | App Store Connect, iPad 13" display (only if the app is offered on iPad) |
| app-store/apple-watch-416x496/ | App Store Connect, Apple Watch (only if the watch app ships; real captures) |
| app-store/app-icon-1024.png | Reference for the 1024x1024 App Store icon (it lives in the Xcode asset catalog) |

Order the screenshots: people, places, chat, sos, check-in, circles, private.

{notes}
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--raw", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--brand", required=True)
    ap.add_argument("--watch", required=True)
    a = ap.parse_args()

    with open(os.path.join(a.raw, "manifest.json")) as f:
        man = json.load(f)
    font = os.path.join(a.raw, "Roboto-Bold.ttf")
    if not os.path.exists(font):
        sys.exit("Roboto-Bold.ttf missing in the raw folder (FLUTTER_ROOT was not set in the render step)")

    for d in ("google-play", "app-store"):
        os.makedirs(os.path.join(a.out, d), exist_ok=True)
    count = 0
    for slot in man["slots"]:
        dest = os.path.join(a.out, SLOT_DIRS[slot["name"]])
        os.makedirs(dest, exist_ok=True)
        for i, shot in enumerate(man["shots"], 1):
            src = os.path.join(a.raw, f"{slot['name']}__{shot['name']}.png")
            if not os.path.exists(src):
                sys.exit(f"missing render {src}")
            img = compose(slot, src, shot["caption"], font)
            assert img.size == (slot["w"], slot["h"]), (img.size, slot)
            img.save(os.path.join(dest, f"{i:02d}-{shot['name']}.png"), optimize=True)
            count += 1

    feature_graphic(a.brand, a.raw, font, os.path.join(a.out, "google-play/feature-graphic-1024x500.png"))
    icon = Image.open(os.path.join(a.brand, "orbitly-app-icon.png")).convert("RGB")
    icon.resize((512, 512), Image.LANCZOS).save(os.path.join(a.out, "google-play/icon-512.png"), optimize=True)
    icon.resize((1024, 1024), Image.LANCZOS).save(os.path.join(a.out, "app-store/app-icon-1024.png"), optimize=True)

    notes = []
    watch_images(a.watch, a.out, notes)
    import datetime
    with open(os.path.join(a.out, "README.md"), "w") as f:
        f.write(README.format(when=datetime.date.today().isoformat(), notes="\n".join("- " + n for n in notes)))
    print(f"wrote {count} screenshots + feature graphic + icons to {a.out}")


if __name__ == "__main__":
    main()
