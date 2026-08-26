#!/usr/bin/env python3
"""sheet.py -- before/after contact sheet, so 151 sprites can be reviewed in
one pass instead of one at a time. Bad conversions are obvious at this size."""
import argparse, os, glob
import numpy as np
from PIL import Image, ImageDraw

ap = argparse.ArgumentParser()
ap.add_argument("--before", required=True)
ap.add_argument("--after", required=True)
ap.add_argument("-o", "--out", default="sheet.png")
ap.add_argument("--cols", type=int, default=8)
ap.add_argument("--zoom", type=int, default=2)
a = ap.parse_args()

names = sorted(os.path.splitext(os.path.basename(p))[0]
               for p in glob.glob(os.path.join(a.after, "*.png")))
S = 58 * a.zoom
CW, CH, PAD = S * 2 + 6, S + 16, 8
cols = a.cols
rows = (len(names) + cols - 1) // cols
sheet = Image.new("RGBA", (PAD + cols * (CW + PAD), PAD + rows * (CH + PAD)), (32, 34, 40, 255))
d = ImageDraw.Draw(sheet)

for i, n in enumerate(names):
    x = PAD + (i % cols) * (CW + PAD)
    y = PAD + (i // cols) * (CH + PAD)
    for j, folder in enumerate((a.before, a.after)):
        p = os.path.join(folder, n + ".png")
        if not os.path.exists(p):
            continue
        im = Image.open(p).convert("RGBA").resize((S, S), Image.NEAREST)
        bg = Image.new("RGBA", (S, S), (52, 54, 62, 255) if j == 0 else (46, 48, 56, 255))
        bg.alpha_composite(im)
        sheet.paste(bg, (x + j * (S + 6), y))
    arr = np.array(Image.open(os.path.join(a.after, n + ".png")).convert("RGBA"))
    k = len(np.unique(arr[..., :3][arr[..., 3] > 0].reshape(-1, 3), axis=0))
    d.text((x + 2, y + S + 2), "%s  %d" % (n, k),
           fill=(255, 140, 140, 255) if k > 16 else (200, 202, 210, 255))

sheet.save(a.out)
print("%d sprites -> %s" % (len(names), a.out))
