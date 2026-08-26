#!/usr/bin/env python3
"""
palettize3.py -- rebuild a resampled truecolor sprite on a small hand-style
palette: an ink contour, then a primary / shadow / highlight ramp per colour
family.

WHAT CHANGED FROM v2, and why (all four from Matt's review of the 150):

1. TONES SPLIT ON LIGHTNESS *AND* CHROMA.
   v2 split a family by lightness alone. Measured on dragonite, the chroma
   spread inside every single lightness band is 0.07-0.09 -- the cream belly
   and the tan skin sit at the SAME lightness and differ only in saturation.
   Lightness-only splitting collapses them into one colour. This is why the
   failures clustered in browns and yellows: that is exactly where
   cream-vs-tan-vs-orange carries the design. Tones are now found in the
   (L, C) plane.

2. HUE IS NOT USED WHERE HUE IS MEANINGLESS.
   57% of marowak's pixels have chroma < 0.06, and their hue spans 100 degrees
   -- noise, not colour. v2 still assigned them to a hue family, which sprayed
   brown onto a grey skull, purple onto mewtwo and splotches onto cubone. The
   achromatic band is now wider and adaptive to each sprite.

3. SALIENT SMALL FAMILIES SURVIVE.
   v2 dropped any family under min_share of the sprite, which ate ninetales'
   red eyes, persian's red dot, pidgeotto's red crest and poliwag's pink
   mouth. A family that is small BUT strongly saturated is a deliberate accent
   and is now kept regardless of population.

4. BLOBS, NOT JUST LONE PIXELS, GET CLEANED.
   v2 despeckled single pixels only, so 3-6 pixel misassignments survived.
   Cleanup now runs on connected components, and still refuses to touch any
   region carrying real lightness contrast -- which is what protects the eyes
   and body spots that v1 destroyed.

Silhouette and canvas are never touched. Alpha comes out byte-identical, which
is what BattleArt.addWhiteOutline needs.
"""

import argparse
import json
import os
from collections import deque
import numpy as np
from PIL import Image

# ---------------------------------------------------------------- colour math

def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64) / 255.0
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.clip(c, 0.0, 1.0)
    s = np.where(c <= 0.0031308, c * 12.92, 1.055 * (c ** (1 / 2.4)) - 0.055)
    return np.clip(np.rint(s * 255.0), 0, 255).astype(np.uint8)


_M1 = np.array([[0.4122214708, 0.5363325363, 0.0514459929],
                [0.2119034982, 0.6806995451, 0.1073969566],
                [0.0883024619, 0.2817188376, 0.6299787005]])
_M2 = np.array([[0.2104542553, 0.7936177850, -0.0040720468],
                [1.9779984951, -2.4285922050, 0.4505937099],
                [0.0259040371, 0.7827717662, -0.8086757660]])
_M1i, _M2i = np.linalg.inv(_M1), np.linalg.inv(_M2)


def rgb_to_oklab(rgb):
    return np.cbrt(np.maximum(srgb_to_linear(rgb) @ _M1.T, 0.0)) @ _M2.T


def oklab_to_linear(lab):
    return ((np.asarray(lab) @ _M2i.T) ** 3) @ _M1i.T


def oklab_to_rgb(lab):
    return linear_to_srgb(oklab_to_linear(lab))


def gamut_clip(L, C, h):
    """Reduce chroma until displayable. Lightness and hue are preserved."""
    out = np.zeros((len(L), 3))
    for i in range(len(L)):
        def ok(c):
            lin = oklab_to_linear(np.array([[L[i], c * np.cos(h[i]),
                                             c * np.sin(h[i])]]))[0]
            return (lin >= -1e-4).all() and (lin <= 1 + 1e-4).all()
        lo, hi = 0.0, float(C[i])
        if ok(hi):
            lo = hi
        else:
            for _ in range(28):
                mid = (lo + hi) / 2
                if ok(mid):
                    lo = mid
                else:
                    hi = mid
        out[i] = [L[i], lo * np.cos(h[i]), lo * np.sin(h[i])]
    return out


# ----------------------------------------------------------------- clustering

def kmeans(X, w, k, iters=80):
    """Weighted k-means with farthest-point init -- deterministic, no seed."""
    k = int(max(1, min(k, len(np.unique(X, axis=0)))))
    cent = [X[int(np.argmax(w))]]
    for _ in range(k - 1):
        d = np.min(((X[:, None, :] - np.array(cent)[None]) ** 2).sum(-1), axis=1)
        j = int(np.argmax(d * w))
        if d[j] <= 1e-12:
            break
        cent.append(X[j])
    cent = np.array(cent, dtype=np.float64)
    asg = np.full(len(X), -1)
    for it in range(iters):
        new = ((X[:, None, :] - cent[None]) ** 2).sum(-1).argmin(1)
        if it and (new == asg).all():
            break
        asg = new
        for i in range(len(cent)):
            m = asg == i
            if m.sum():
                cent[i] = np.average(X[m], axis=0, weights=w[m])
    return cent, asg


def circular_kmeans(h, w, k, iters=60):
    k = max(1, int(k))
    cent = np.array([2 * np.pi * i / k for i in range(k)])
    asg = np.full(len(h), -1)
    for it in range(iters):
        new = np.abs(np.angle(np.exp(1j * (h[:, None] - cent[None])))).argmin(1)
        if it and (new == asg).all():
            break
        asg = new
        for i in range(k):
            m = asg == i
            if m.sum():
                z = (w[m] * np.exp(1j * h[m])).sum()
                if abs(z) > 0:
                    cent[i] = np.angle(z)
    return cent, asg


def components(lmap, mask):
    """8-connected components of equal label. No scipy on the target machine."""
    H, W = lmap.shape
    comp = np.full((H, W), -1)
    sizes = []
    for y in range(H):
        for x in range(W):
            if not mask[y, x] or comp[y, x] >= 0:
                continue
            cid = len(sizes)
            lab = lmap[y, x]
            q = deque([(y, x)])
            comp[y, x] = cid
            n = 0
            while q:
                cy, cx = q.popleft()
                n += 1
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < H and 0 <= nx < W and mask[ny, nx] \
                                and comp[ny, nx] < 0 and lmap[ny, nx] == lab:
                            comp[ny, nx] = cid
                            q.append((ny, nx))
            sizes.append(n)
    return comp, np.array(sizes)


# -------------------------------------------------------------------- process

def palettize(img, ramp=4, ink_l=0.30, ink_share=0.30, ink_hex="#000000",
              core_edge=0.075, core_weight=0.10,
              neutral_c=0.050, neutral_adaptive=True, neutral_tones=3,
              salient_c=0.100, salient_px=4,
              min_sep=26.0, max_families=6, min_share=0.015,
              step=0.085, chroma_sep=0.035, max_drop=0.34,
              shadow_chroma=1.10, primary_chroma=1.04,
              chroma_weight=1.9, white_l=0.95,
              min_blob=6, blob_keep=0.10, despeckle=2):
    a = np.array(img.convert("RGBA"))
    alpha = a[..., 3]
    mask = alpha >= 128
    rgb = a[..., :3][mask]
    if not len(rgb):
        return img.convert("RGBA"), []

    lab = rgb_to_oklab(rgb)
    L, n = lab[:, 0], len(lab)
    C = np.hypot(lab[:, 1], lab[:, 2])
    hu = np.arctan2(lab[:, 2], lab[:, 1])

    # Core weighting: a pixel on a boundary in the source is a blend of two
    # materials. It still gets assigned a tone, but it must not get a vote on
    # what that tone IS, or small features get defined by their own halo.
    lum = np.zeros(alpha.shape)
    lum[mask] = L
    grad = np.zeros(alpha.shape)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if (dy, dx) == (0, 0):
                continue
            sh = np.roll(np.roll(lum, dy, 0), dx, 1)
            sm = np.roll(np.roll(mask, dy, 0), dx, 1)
            grad = np.maximum(grad, np.abs(lum - sh) * (mask & sm))
    w = np.where(grad[mask] > core_edge, core_weight, 1.0)

    # ---- 1. ink band -------------------------------------------------------
    t = ink_l
    if (L < t).mean() > ink_share:
        t = float(np.quantile(L, ink_share))
    is_ink = L < t

    # ---- 2. achromatic band ------------------------------------------------
    # Hue is only meaningful above some chroma. Below it, the angle is noise
    # and using it sprays colour onto grey. Adapt the cut to the sprite: if a
    # sprite is mostly pale, its own low quantile is a better cut than a fixed
    # constant, but never go below the fixed floor.
    cut = neutral_c
    if neutral_adaptive and (~is_ink).sum() > 30:
        cut = max(neutral_c, float(np.quantile(C[~is_ink], 0.15)))
        cut = min(cut, 0.085)
    rest = ~is_ink
    is_white = rest & (L >= white_l) & (C < cut)
    is_neu = rest & ~is_white & (C < cut)
    is_chr = rest & ~is_white & ~is_neu

    tones = []          # [family, role, L, C, hue, member_index_array]

    # ---- 3. hue families ---------------------------------------------------
    fam_of = {}
    if is_chr.sum():
        idx = np.nonzero(is_chr)[0]
        hw = w[idx] * np.maximum(C[idx], 1e-3)
        _, asg = circular_kmeans(hu[idx], hw, min(max_families, len(idx)))

        while True:
            uniq = sorted(set(asg.tolist()))
            if len(uniq) < 2:
                break
            cen = np.array([np.angle((hw[asg == u] * np.exp(1j * hu[idx][asg == u])).sum())
                            for u in uniq])
            share = np.array([(asg == u).sum() / n for u in uniq])
            chrom = np.array([np.average(C[idx][asg == u]) for u in uniq])
            cnt = np.array([(asg == u).sum() for u in uniq])
            d = np.abs(np.angle(np.exp(1j * (cen[:, None] - cen[None]))))
            np.fill_diagonal(d, np.inf)

            # A small family that is strongly saturated is an accent -- a red
            # eye, a pink mouth, a crest -- not noise. Keep it whatever its size.
            salient = (chrom >= salient_c) & (cnt >= salient_px)
            droppable = (share < min_share) & ~salient
            if droppable.any():
                s = int(np.nonzero(droppable)[0][np.argmin(share[droppable])])
                tgt = int(np.argmin(d[s]))
                asg[asg == uniq[s]] = uniq[tgt]
                continue
            i, j = np.unravel_index(np.argmin(d), d.shape)
            if d[i, j] < np.deg2rad(min_sep) and not (salient[i] ^ salient[j]):
                asg[asg == uniq[int(j)]] = uniq[int(i)]
                continue
            break

        for u in sorted(set(asg.tolist())):
            fam_of["hue%03d" % int(np.rad2deg(np.angle(
                (hw[asg == u] * np.exp(1j * hu[idx][asg == u])).sum())) % 360)] = idx[asg == u]
    if is_neu.sum():
        fam_of["neutral"] = np.nonzero(is_neu)[0]
    if is_white.sum():
        fam_of["white"] = np.nonzero(is_white)[0]

    # ---- 4. tones inside a family, in the (L, C) plane ---------------------
    for fam, sel in fam_of.items():
        if fam == "white":
            tones.append([fam, "primary", 1.0, 0.0, 0.0, sel])
            continue
        k = neutral_tones if fam == "neutral" else ramp
        span = max(L[sel].max() - L[sel].min(),
                   (C[sel].max() - C[sel].min()) * chroma_weight)
        k = int(np.clip(np.ceil(span / step), 1, k))
        X = np.stack([L[sel], C[sel] * chroma_weight], 1)
        _, sub = kmeans(X, np.maximum(w[sel], 1e-3), k)
        groups = []
        for tix in sorted(set(sub.tolist())):
            s = sel[sub == tix]
            if not len(s):
                continue
            ws = np.maximum(w[s], 1e-3)
            z = (ws * np.maximum(C[s], 1e-3) * np.exp(1j * hu[s])).sum()
            groups.append([float(np.average(L[s], weights=ws)),
                           float(np.average(C[s], weights=ws)),
                           float(np.angle(z)) if abs(z) > 0 else 0.0, s])
        groups.sort(key=lambda g: -g[0])
        for gi, g in enumerate(groups):
            role = ("primary" if gi == 0 else
                    "shadow" if gi == len(groups) - 1 else "mid%d" % gi)
            tones.append([fam, role, g[0], g[1], g[2], g[3]])

    # ---- 5. enforce the ramp ----------------------------------------------
    byfam = {}
    for t_ in tones:
        byfam.setdefault(t_[0], []).append(t_)
    for fam, group in byfam.items():
        if fam == "white":
            continue
        group.sort(key=lambda g: -g[2])
        top = group[0][2]
        for gi, g in enumerate(group):
            if gi == 0:
                g[3] *= primary_chroma
                continue
            prev = group[gi - 1]
            # Two tones already separated by SATURATION do not need to be
            # forced apart in lightness as well -- that is what turns a cream
            # belly into a hard band instead of a soft one.
            if abs(g[3] - prev[3]) < chroma_sep:
                g[2] = min(g[2], prev[2] - step)
            g[3] *= shadow_chroma
            g[2] = float(np.clip(g[2], max(0.05, top - max_drop), 1.0))

    # ---- 6. resolve colours -----------------------------------------------
    cols = list(oklab_to_rgb(gamut_clip(
        np.array([t_[2] for t_ in tones]),
        np.array([t_[3] for t_ in tones]),
        np.array([t_[4] for t_ in tones]))))
    if is_ink.sum():
        ih = ink_hex.lstrip("#")
        tones.append(["ink", "ink", 0.0, 0.0, 0.0, np.nonzero(is_ink)[0]])
        cols.append(np.array([int(ih[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.uint8))

    label = np.full(n, -1, dtype=int)
    for i, t_ in enumerate(tones):
        label[t_[5]] = i
    ntone = len(tones)
    toneL = np.array([t_[2] for t_ in tones])

    lmap = np.full(alpha.shape, -1, dtype=int)
    lmap[mask] = label

    # ---- 7. clean misassigned regions, protecting real contrast -----------
    for _ in range(max(0, despeckle)):
        comp, sizes = components(lmap, mask)
        changed = False
        for cid, sz in enumerate(sizes):
            if sz >= min_blob:
                continue
            sel = comp == cid
            mine = int(lmap[sel.argmax() // lmap.shape[1], sel.argmax() % lmap.shape[1]]) \
                if False else int(lmap[sel][0])
            ring = {}
            ys, xs = np.nonzero(sel)
            for y, x in zip(ys, xs):
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = y + dy, x + dx
                        if 0 <= ny < lmap.shape[0] and 0 <= nx < lmap.shape[1] \
                                and mask[ny, nx] and comp[ny, nx] != cid:
                            ring[lmap[ny, nx]] = ring.get(lmap[ny, nx], 0) + 1
            if not ring:
                continue
            host = max(ring, key=ring.get)
            # A small region that is genuinely darker or lighter than what
            # surrounds it is a mark -- an eye, a spot, a vein. Leave it. A
            # small region that merely differs in HUE at the same lightness is
            # a misassignment. Absorb it.
            if abs(toneL[mine] - toneL[host]) <= blob_keep:
                lmap[sel] = host
                changed = True
        if not changed:
            break

    lut = np.array(cols, dtype=np.uint8)
    out = a.copy()
    out[..., :3][mask] = lut[lmap[mask]]
    out[..., 3] = alpha

    palette = []
    for i, t_ in enumerate(tones):
        cnt = int((lmap == i).sum())
        if cnt:
            palette.append({"family": t_[0], "role": t_[1], "pixels": cnt,
                            "hex": "#%02X%02X%02X" % tuple(int(x) for x in lut[i])})
    return Image.fromarray(out, "RGBA"), palette


# --------------------------------------------------------------------- driver

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--outdir", required=True)
    ap.add_argument("--ramp", type=int, default=4)
    ap.add_argument("--ink-l", type=float, default=0.30)
    ap.add_argument("--ink-share", type=float, default=0.30)
    ap.add_argument("--ink", dest="ink_hex", default="#000000")
    ap.add_argument("--core-edge", type=float, default=0.075)
    ap.add_argument("--core-weight", type=float, default=0.10)
    ap.add_argument("--neutral-c", type=float, default=0.050,
                    help="chroma below which hue is treated as meaningless")
    ap.add_argument("--no-neutral-adaptive", action="store_true")
    ap.add_argument("--neutral-tones", type=int, default=3)
    ap.add_argument("--salient-c", type=float, default=0.100,
                    help="a family this saturated is kept however small")
    ap.add_argument("--salient-px", type=int, default=4)
    ap.add_argument("--min-sep", type=float, default=26.0)
    ap.add_argument("--max-families", type=int, default=6)
    ap.add_argument("--min-share", type=float, default=0.015)
    ap.add_argument("--step", type=float, default=0.085)
    ap.add_argument("--chroma-sep", type=float, default=0.035,
                    help="tones this far apart in chroma are not forced apart in lightness")
    ap.add_argument("--max-drop", type=float, default=0.34,
                    help="cap on how far below its primary a family's darkest tone may go")
    ap.add_argument("--shadow-chroma", type=float, default=1.10)
    ap.add_argument("--primary-chroma", type=float, default=1.04)
    ap.add_argument("--chroma-weight", type=float, default=1.9,
                    help="how much saturation counts vs lightness when splitting tones")
    ap.add_argument("--white-l", type=float, default=0.95)
    ap.add_argument("--min-blob", type=int, default=6,
                    help="regions smaller than this are candidates for cleanup")
    ap.add_argument("--blob-keep", type=float, default=0.10,
                    help="never absorb a region carrying this much lightness contrast")
    ap.add_argument("--despeckle", type=int, default=2)
    ap.add_argument("--overrides", default=None)
    ap.add_argument("--report", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    ov = json.load(open(args.overrides)) if args.overrides else {}
    os.makedirs(args.outdir, exist_ok=True)
    base = {k: v for k, v in vars(args).items()
            if k not in ("inputs", "outdir", "overrides", "report", "quiet",
                         "no_neutral_adaptive")}
    base["neutral_adaptive"] = not args.no_neutral_adaptive
    report = {}

    for p in sorted(args.inputs):
        name = os.path.splitext(os.path.basename(p))[0]
        kw = dict(base)
        kw.update(ov.get(name, {}))
        src = Image.open(p)
        before = np.array(src.convert("RGBA"))
        out, pal = palettize(src, **kw)
        after = np.array(out)
        assert before.shape == after.shape, "size changed: " + name
        assert (before[..., 3] == after[..., 3]).all(), "alpha changed: " + name
        out.save(os.path.join(args.outdir, name + ".png"))
        nb = len(np.unique(before[..., :3][before[..., 3] > 0].reshape(-1, 3), axis=0))
        report[name] = {"before": int(nb), "after": len(pal), "palette": pal}
        if not args.quiet:
            print("%-14s %5d -> %2d   %s" % (name, nb, len(pal),
                                             " ".join(x["hex"] for x in pal)))
    if args.report:
        json.dump(report, open(args.report, "w"), indent=2)


if __name__ == "__main__":
    main()
