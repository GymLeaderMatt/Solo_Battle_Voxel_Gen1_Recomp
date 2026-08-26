#!/usr/bin/env python3
"""
palettize2.py -- rebuild a resampled truecolor sprite on a small hand-style
palette: an ink contour, then a ramp of primary / shadow / highlight per
colour family.

Modelled directly on Matt's hand-cut Weedle, which turned out to be:

    brown family   #FED08C  #E4A956  #CE8951  #6A390A   -> ramp, 3-4 tones
    red family     #D56B71  #8F2500                     -> its own family
    ink            #000000                              -> darkest band, CRUSHED
    white          #FFFFFF                              -> left alone

The two things a naive quantiser gets wrong, both visible in that file:

1. The darkest band is not "the shadow of the brown". It is pushed all the way
   to pure black and used as contour. Nearest-colour matching reproduces only
   7% of those pixels; an explicit ink rule reproduces them.
2. The red nose is its own family, not a dark tone of the brown. Its hue sits
   ~16 deg off the body's, which is under any sane merge threshold -- so
   families are split on hue with a fine separation, not by generic clustering.

Silhouette and canvas are never touched. Alpha comes out byte-identical, which
is what BattleArt.addWhiteOutline needs.
"""

import argparse
import json
import os
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
    out = np.zeros((len(L), 3))
    for i in range(len(L)):
        lo, hi = 0.0, float(C[i])
        def ok(c):
            lin = oklab_to_linear(np.array([[L[i], c * np.cos(h[i]), c * np.sin(h[i])]]))[0]
            return (lin >= -1e-4).all() and (lin <= 1 + 1e-4).all()
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


# --------------------------------------------------------------- 1-D partition

def jenks(v, w, k):
    """Exact weighted 1-D k-partition on lightness.

    Values are binned to 1/1024 first. The DP is O(k*bins^2), so cost depends on
    the bin count rather than the pixel count -- a 198x198 master costs the same
    as a 58x58 one. 1024 bins is far finer than 8-bit output can express, so
    binning changes no result."""
    BINS = 1024
    if len(v) > BINS:
        q = np.clip((v * (BINS - 1)).astype(int), 0, BINS - 1)
        centres = np.bincount(q, weights=w * v, minlength=BINS)
        weights = np.bincount(q, weights=w, minlength=BINS)
        nz = weights > 0
        cv = centres[nz] / weights[nz]
        sub = jenks(cv, weights[nz], k)
        lookup = np.zeros(BINS, dtype=int)
        lookup[np.nonzero(nz)[0]] = sub
        return lookup[q]
    order = np.argsort(v)
    x, ww = v[order], w[order]
    n = len(x)
    k = max(1, min(k, n))
    cw = np.concatenate([[0.0], np.cumsum(ww)])
    cs = np.concatenate([[0.0], np.cumsum(ww * x)])
    cq = np.concatenate([[0.0], np.cumsum(ww * x * x)])

    def sse(i, j):
        tw = cw[j] - cw[i]
        if tw <= 0:
            return 0.0
        s = cs[j] - cs[i]
        return (cq[j] - cq[i]) - s * s / tw

    INF = float("inf")
    dp = np.full((k + 1, n + 1), INF)
    bk = np.zeros((k + 1, n + 1), dtype=int)
    dp[0, 0] = 0.0
    for c in range(1, k + 1):
        for j in range(c, n + 1):
            best, arg = INF, c - 1
            for i in range(c - 1, j):
                if dp[c - 1, i] == INF:
                    continue
                val = dp[c - 1, i] + sse(i, j)
                if val < best:
                    best, arg = val, i
            dp[c, j], bk[c, j] = best, arg
    cuts, j = [n], n
    for c in range(k, 0, -1):
        j = bk[c, j]
        cuts.append(j)
    cuts = cuts[::-1]
    lab = np.zeros(n, dtype=int)
    for c in range(k):
        lab[cuts[c]:cuts[c + 1]] = c
    out = np.zeros(len(v), dtype=int)
    out[order] = lab
    return out


def circular_kmeans(h, w, k, iters=60):
    """Deterministic circular k-means on hue. Returns centre angles."""
    k = max(1, k)
    cent = np.array([2 * np.pi * i / k for i in range(k)])
    asg = np.zeros(len(h), dtype=int)
    for _ in range(iters):
        d = np.abs(np.angle(np.exp(1j * (h[:, None] - cent[None]))))
        new = d.argmin(1)
        if (new == asg).all() and _:
            break
        asg = new
        for i in range(k):
            m = asg == i
            if m.sum():
                z = (w[m] * np.exp(1j * h[m])).sum()
                if abs(z) > 0:
                    cent[i] = np.angle(z)
    return cent, asg


# -------------------------------------------------------------------- process

def palettize(img, ramp=4, ink_l=0.30, ink_share=0.30, ink_hex="#000000",
              core_edge=0.075, core_weight=0.10, flatten=0.03,
              flatten_keep=0.08, despeckle_keep=0.10,
              ink_keep_hue=0.0, min_sep=26.0, max_families=5, min_share=0.015,
              chroma_floor=0.035, step=0.085, shadow_chroma=1.10,
              primary_chroma=1.04, neutral_tones=3, white_l=0.93,
              despeckle=2, protect=None):
    a = np.array(img.convert("RGBA"))
    alpha = a[..., 3]
    mask = alpha >= 128
    rgb = a[..., :3][mask]
    if not len(rgb):
        return img.convert("RGBA"), []

    lab = rgb_to_oklab(rgb)
    L = lab[:, 0]
    C = np.hypot(lab[:, 1], lab[:, 2])
    hu = np.arctan2(lab[:, 2], lab[:, 1])
    n = len(L)

    # Core weighting. A pixel that sits on a boundary in the source is a blend
    # of two materials -- it is anti-aliasing, not a colour anyone chose. Such
    # pixels still get assigned a tone, but they must not get a vote on what
    # that tone IS, or every small feature (a nose, a mouth) ends up defined by
    # its own halo and comes out washed toward whatever surrounds it.
    lum = np.zeros(alpha.shape)
    lum[mask] = L
    grad = np.zeros(alpha.shape)
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            if dy == 0 and dx == 0:
                continue
            sh = np.roll(np.roll(lum, dy, 0), dx, 1)
            sm = np.roll(np.roll(mask, dy, 0), dx, 1)
            grad = np.maximum(grad, np.abs(lum - sh) * (mask & sm))
    edge = grad[mask]
    w = np.where(edge > core_edge, core_weight, 1.0)

    # ---- 1. ink band -------------------------------------------------------
    t = ink_l
    if (L < t).mean() > ink_share:
        t = float(np.quantile(L, ink_share))
    is_ink = L < t

    # ---- 2. neutral vs chromatic ------------------------------------------
    rest = ~is_ink
    is_white = rest & (L >= white_l) & (C < chroma_floor * 1.6)
    is_neu = rest & ~is_white & (C < chroma_floor)
    is_chr = rest & ~is_white & ~is_neu

    label = np.full(n, -1, dtype=int)
    tones = []           # (family_name, role, L, C, h, member_mask)

    def add(name, role, m, Lv, Cv, hv):
        tones.append([name, role, Lv, Cv, hv, m])

    # ---- 3. hue families ---------------------------------------------------
    if is_chr.sum():
        idx = np.nonzero(is_chr)[0]
        hw = w[idx] * np.maximum(C[idx], 1e-3)
        k = min(max_families, max(1, len(idx)))
        cent, asg = circular_kmeans(hu[idx], hw, k)

        # merge centres that are too close, then drop tiny families
        while True:
            uniq = sorted(set(asg.tolist()))
            cent_u = np.array([np.angle((hw[asg == u] * np.exp(1j * hu[idx][asg == u])).sum())
                               for u in uniq])
            if len(uniq) < 2:
                break
            d = np.abs(np.angle(np.exp(1j * (cent_u[:, None] - cent_u[None]))))
            np.fill_diagonal(d, np.inf)
            share = np.array([(asg == u).sum() / n for u in uniq])
            i, j = np.unravel_index(np.argmin(d), d.shape)
            small = np.argmin(share)
            if share[small] < min_share:
                tgt = int(np.argmin(np.where(np.arange(len(uniq)) == small, np.inf,
                                             d[small])))
                asg[asg == uniq[small]] = uniq[tgt]
            elif d[i, j] < np.deg2rad(min_sep):
                asg[asg == uniq[j]] = uniq[i]
            else:
                break

        for fi, u in enumerate(sorted(set(asg.tolist()))):
            sel = idx[asg == u]
            fam = "hue%03d" % int(np.rad2deg(np.angle(
                (np.maximum(C[sel], 1e-3) * np.exp(1j * hu[sel])).sum())) % 360)
            span = L[sel].max() - L[sel].min()
            k2 = int(np.clip(np.ceil(span / step), 2, ramp))
            k2 = min(k2, len(np.unique(np.round(L[sel], 4))))
            sub = jenks(L[sel], w[sel], k2)
            groups = []
            for tix in range(k2):
                s = sel[sub == tix]
                if not len(s):
                    continue
                ws0 = np.maximum(w[s], 1e-3)
                z = (np.maximum(C[s], 1e-3) * np.exp(1j * hu[s])).sum()
                ws = np.maximum(w[s], 1e-3)
                groups.append([float(np.average(L[s], weights=ws)), float(np.average(C[s], weights=ws)),
                               float(np.angle(z)), s])
            groups.sort(key=lambda g: -g[0])
            for gi, g in enumerate(groups):
                role = ("highlight" if (gi == 0 and len(groups) > 2) else
                        "primary" if gi == 0 or (gi == 1 and len(groups) > 2) else
                        "shadow" if gi == len(groups) - 1 else "mid%d" % gi)
                add(fam, role, g[3], g[0], g[1], g[2])

    # ---- 4. neutrals and white --------------------------------------------
    if is_neu.sum():
        sel = np.nonzero(is_neu)[0]
        k2 = min(neutral_tones, len(np.unique(np.round(L[sel], 3))))
        sub = jenks(L[sel], w[sel], k2)
        gs = []
        for tix in range(k2):
            s = sel[sub == tix]
            if len(s):
                gs.append([float(np.average(L[s])), float(np.average(C[s])),
                           float(np.average(hu[s])), s])
        gs.sort(key=lambda g: -g[0])
        for gi, g in enumerate(gs):
            add("neutral", "primary" if gi == 0 else "shadow", g[3], g[0], g[1], g[2])
    if is_white.sum():
        s = np.nonzero(is_white)[0]
        add("white", "primary", s, 1.0, 0.0, 0.0)

    # ---- 4b. flatten: a tone almost nobody uses is noise, not a shade ------
    if flatten > 0:
        byfam = {}
        for ti, t_ in enumerate(tones):
            byfam.setdefault(t_[0], []).append(ti)
        for fam, ids in byfam.items():
            if len(ids) < 2:
                continue
            changed = True
            while changed and len(ids) > 1:
                changed = False
                ids.sort(key=lambda i: -tones[i][2])
                for pos, ti in enumerate(ids):
                    if len(tones[ti][5]) / n >= flatten:
                        continue
                    nb = ids[pos - 1] if pos else ids[1]
                    # A rare tone that is FAR from its neighbour is a feature --
                    # an eye, a spot, a leaf vein. Only rare-and-similar tones
                    # are resample noise worth collapsing.
                    if abs(tones[ti][2] - tones[nb][2]) > flatten_keep:
                        continue
                    tones[nb][5] = np.concatenate([tones[nb][5], tones[ti][5]])
                    sel2 = tones[nb][5]
                    ws2 = np.maximum(w[sel2], 1e-3)
                    tones[nb][2] = float(np.average(L[sel2], weights=ws2))
                    tones[nb][3] = float(np.average(C[sel2], weights=ws2))
                    tones[ti][5] = np.array([], dtype=int)
                    ids.remove(ti)
                    changed = True
                    break
        tones[:] = [t_ for t_ in tones if len(t_[5])]

    # ---- 5. enforce the ramp ----------------------------------------------
    fams = {}
    for t_ in tones:
        fams.setdefault(t_[0], []).append(t_)
    for fam, group in fams.items():
        group.sort(key=lambda g: -g[2])
        for gi, g in enumerate(group):
            if gi == 0:
                g[3] *= primary_chroma
            else:
                g[2] = min(g[2], group[gi - 1][2] - step)
                g[3] *= shadow_chroma
            g[2] = float(np.clip(g[2], 0.05, 1.0))

    # ---- 6. resolve colours -----------------------------------------------
    Ls = np.array([t_[2] for t_ in tones])
    Cs = np.array([t_[3] for t_ in tones])
    hs = np.array([t_[4] for t_ in tones])
    cols = list(oklab_to_rgb(gamut_clip(Ls, Cs, hs)))

    if is_ink.sum():
        ih = ink_hex.lstrip("#")
        base = np.array([int(ih[i:i + 2], 16) for i in (0, 2, 4)])
        if ink_keep_hue > 0:
            z = (np.maximum(C[is_ink], 1e-3) * np.exp(1j * hu[is_ink])).sum()
            lab_i = gamut_clip(np.array([rgb_to_oklab(base[None])[0][0] + 0.001]),
                               np.array([ink_keep_hue]), np.array([np.angle(z)]))
            base = oklab_to_rgb(lab_i)[0]
        tones.append(["ink", "ink", 0.0, 0.0, 0.0, np.nonzero(is_ink)[0]])
        cols.append(np.array(base, dtype=np.uint8))

    for i, t_ in enumerate(tones):
        label[t_[5]] = i
    ntone = len(tones)

    # ---- 7. despeckle in label space --------------------------------------
    lmap = np.full(alpha.shape, -1, dtype=int)
    lmap[mask] = label
    for _ in range(max(0, despeckle)):
        pad = np.pad(lmap, 1, constant_values=-1)
        H, W = lmap.shape
        stack = np.stack([pad[1 + dy:1 + dy + H, 1 + dx:1 + dx + W]
                          for dy in (-1, 0, 1) for dx in (-1, 0, 1) if (dy, dx) != (0, 0)])
        new = lmap.copy()
        toneL = np.array([t_[2] for t_ in tones] + [0.0])
        for lb in range(ntone):
            cand = mask & (lmap != lb) & ((stack == lb).sum(0) >= 6)
            if not cand.any():
                continue
            # only absorb a pixel into its neighbours if it is not carrying
            # real contrast. A lone dark pixel on a light field is detail.
            near = np.abs(toneL[lmap] - toneL[lb]) <= despeckle_keep
            new[cand & near] = lb
        if (new == lmap).all():
            break
        lmap = new

    lut = np.array(cols, dtype=np.uint8)
    out = a.copy()
    out[..., :3][mask] = lut[lmap[mask]]
    out[..., 3] = alpha

    palette = []
    for i, t_ in enumerate(tones):
        cnt = int((lmap == i).sum())
        if cnt:
            palette.append({"family": t_[0], "role": t_[1],
                            "hex": "#%02X%02X%02X" % tuple(int(x) for x in lut[i]),
                            "pixels": cnt})
    return Image.fromarray(out, "RGBA"), palette


# --------------------------------------------------------------------- driver

def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("inputs", nargs="+")
    ap.add_argument("-o", "--outdir", required=True)
    ap.add_argument("--ramp", type=int, default=4, help="tones per family above the ink")
    ap.add_argument("--ink-l", type=float, default=0.30, help="lightness below which a pixel is contour")
    ap.add_argument("--ink-share", type=float, default=0.30, help="cap on how much of a sprite can be ink")
    ap.add_argument("--ink", dest="ink_hex", default="#000000")
    ap.add_argument("--ink-keep-hue", type=float, default=0.0,
                    help="chroma to keep in the ink (0 = pure black)")
    ap.add_argument("--min-sep", type=float, default=26.0, help="degrees between hue families")
    ap.add_argument("--max-families", type=int, default=5)
    ap.add_argument("--min-share", type=float, default=0.015)
    ap.add_argument("--chroma-floor", type=float, default=0.035)
    ap.add_argument("--step", type=float, default=0.085)
    ap.add_argument("--shadow-chroma", type=float, default=1.10)
    ap.add_argument("--primary-chroma", type=float, default=1.04)
    ap.add_argument("--neutral-tones", type=int, default=3)
    ap.add_argument("--white-l", type=float, default=0.93)
    ap.add_argument("--core-edge", type=float, default=0.075,
                    help="lightness gradient above which a pixel is treated as anti-aliasing")
    ap.add_argument("--core-weight", type=float, default=0.10,
                    help="how much vote a blend pixel gets when choosing colours")
    ap.add_argument("--flatten", type=float, default=0.03,
                    help="merge any tone used by less than this share of the sprite")
    ap.add_argument("--flatten-keep", type=float, default=0.08,
                    help="never merge a rare tone this far in lightness from its neighbour")
    ap.add_argument("--despeckle-keep", type=float, default=0.10,
                    help="never absorb a lone pixel carrying this much contrast")
    ap.add_argument("--despeckle", type=int, default=2)
    ap.add_argument("--overrides", default=None)
    ap.add_argument("--report", default=None)
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    ov = json.load(open(args.overrides)) if args.overrides else {}
    os.makedirs(args.outdir, exist_ok=True)
    base = {k: v for k, v in vars(args).items()
            if k not in ("inputs", "outdir", "overrides", "report", "quiet")}
    report = {}

    for p in sorted(args.inputs):
        name = os.path.splitext(os.path.basename(p))[0]
        kw = dict(base)
        kw.update(ov.get(name, {}))
        src = Image.open(p)
        before = np.array(src.convert("RGBA"))
        out, pal = palettize(src, **kw)
        after = np.array(out)
        assert before.shape == after.shape
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
