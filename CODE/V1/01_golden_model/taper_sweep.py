# -*- coding: utf-8 -*-
"""Taper sweep, take 3 -- vectorised.

Two questions:
  Q1 reproduction: does an independent implementation recover the manuscript's
     20.7 / 21.9 / 21.6 dB for the three taper families at matched group delay?
  Q2 referee #3: does any taper overtake the delayed pair's 25.4 dB once the
     group-delay constraint is relaxed?

Edges are found by vectorised linear interpolation on the -3 dB crossings, so the
2% edge tolerance is no longer comparable to one FFT bin (take 1's fatal bug).
"""
import numpy as np, os, sys
from scipy.stats import norm

D = r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_package\INAUSIS_package\gowin_syn"
NF = 8192
L = 128
FSTOP = 0.2
F = np.fft.rfftfreq(NF, 1.0)
I_STOP = F >= FSTOP
n = np.arange(L)
T3 = 1.0 / np.sqrt(2.0)


def load(p):
    v = [int(x, 16) for x in open(p).read().split()]
    a = np.array([x - 65536 if x > 32767 else x for x in v], float) / 32768.0
    return [a[i * 256:(i + 1) * 256] for i in range(3)]


def mags(K, chunk=1500):
    out = np.empty((len(K), len(F)), dtype=np.float32)
    for i in range(0, len(K), chunk):
        H = np.abs(np.fft.rfft(K[i:i + chunk], NF, axis=-1))
        out[i:i + chunk] = (H / H.max(axis=-1, keepdims=True)).astype(np.float32)
    return out


def edges_vec(Hn):
    """Interpolated -3 dB edges for every row, vectorised."""
    above = Hn >= T3
    any_ = above.any(axis=1)
    lo_i = above.argmax(axis=1)
    hi_i = Hn.shape[1] - 1 - above[:, ::-1].argmax(axis=1)
    r = np.arange(Hn.shape[0])
    lo = np.full(Hn.shape[0], np.nan)
    hi = np.full(Hn.shape[0], np.nan)
    m = any_ & (lo_i > 0)
    a, b = Hn[r[m], lo_i[m] - 1], Hn[r[m], lo_i[m]]
    lo[m] = F[lo_i[m] - 1] + (T3 - a) / np.maximum(b - a, 1e-12) * (F[1] - F[0])
    m2 = any_ & (hi_i < Hn.shape[1] - 1)
    a, b = Hn[r[m2], hi_i[m2]], Hn[r[m2], hi_i[m2] + 1]
    hi[m2] = F[hi_i[m2]] + (a - T3) / np.maximum(a - b, 1e-12) * (F[1] - F[0])
    return lo, hi


K = load(os.path.join(D, "dog_coeffs.mem"))
ref = K[0] - K[1]
Href = mags(ref[None, :])
LO, HI = edges_vec(Href)
LO, HI = float(LO[0]), float(HI[0])
WC_REF = 20 * np.log10(Href[0][I_STOP].max())
A = np.abs(ref)
CEN_REF = float((A * np.arange(256)).sum() / A.sum())
print("implemented delayed pair (shipped ROM)")
print("  -3 dB %.5f / %.5f fs | worst-case %.2f dB | centroid %.2f samples"
      % (LO, HI, WC_REF, CEN_REF))
print("  2%% edge tolerance +/-%.5f (lo) +/-%.5f (hi); FFT bin %.5f"
      % (0.02 * LO, 0.02 * HI, F[1]))
sys.stdout.flush()

S1 = np.arange(1.20, 6.01, 0.12)
S2 = np.arange(4.0, 24.01, 0.30)
MU = np.arange(0.0, 12.01, 0.4)
FAM = {
    "skew-normal": ("skew", [0.5, 1, 2, 3, 4, 6, 9, 14, 20]),
    "one-sided raised-cosine": ("tukey", [1.5, 2, 3, 4, 5, 6, 8, 10, 13, 17, 22]),
    "one-sided exponential": ("exp", [0.4, 0.7, 1.1, 1.6, 2.3, 3.2, 4.5, 6.5, 9, 13]),
}
SLACK = [0.3, 1.3, 2.3, 3.3, 5.3, 1e9]
best = {f: {s: (-1e9, None) for s in SLACK} for f in FAM}

s1g, s2g = np.meshgrid(S1, S2, indexing="ij")
keep = s2g > s1g * 1.5
S1V, S2V = s1g[keep], s2g[keep]
print("  grid: %d (s1,s2) pairs x %d offsets x %d taper settings\n"
      % (len(S1V), len(MU), sum(len(v[1]) for v in FAM.values())))
sys.stdout.flush()

for name, (kind, PS) in FAM.items():
    for p in PS:
        for mu in MU:
            g1 = np.exp(-0.5 * ((n[None, :] - mu) / S1V[:, None]) ** 2)
            g2 = np.exp(-0.5 * ((n[None, :] - mu) / S2V[:, None]) ** 2)
            if kind == "skew":
                g1 = g1 * norm.cdf(p * (n[None, :] - mu) / S1V[:, None])
                g2 = g2 * norm.cdf(p * (n[None, :] - mu) / S2V[:, None])
            elif kind == "tukey":
                M = max(p, 1e-9)
                w = np.where(n < M, 0.5 * (1 - np.cos(np.pi * n / M)), 1.0)
                g1, g2 = g1 * w, g2 * w
            else:
                w = 1.0 - np.exp(-n / max(p, 1e-9))
                g1, g2 = g1 * w, g2 * w
            g1 = g1 / g1.sum(axis=-1, keepdims=True)
            g2 = g2 / g2.sum(axis=-1, keepdims=True)
            Kc = g1 - g2
            Hn = mags(Kc)
            pk = F[Hn.argmax(axis=1)]
            rough = (pk > 0.025) & (pk < 0.09)
            if not rough.any():
                continue
            idx = np.nonzero(rough)[0]
            lo, hi = edges_vec(Hn[idx])
            ok = (np.abs(lo - LO) <= 0.02 * LO) & (np.abs(hi - HI) <= 0.02 * HI)
            if not ok.any():
                continue
            sel = idx[ok]
            wc = 20 * np.log10(Hn[sel][:, I_STOP].max(axis=1))
            Aa = np.abs(Kc[sel])
            cen = (Aa * n).sum(axis=1) / Aa.sum(axis=1)
            for sl in SLACK:
                q = np.abs(cen - CEN_REF) <= sl
                if not q.any():
                    continue
                j = int(np.argmax(np.where(q, wc, -1e9)))
                if wc[j] > best[name][sl][0]:
                    best[name][sl] = (float(wc[j]),
                                      (p, mu, float(S1V[sel][j]), float(S2V[sel][j]), float(cen[j])))
    print("  done:", name)
    sys.stdout.flush()

print()
print("best worst-case rejection over f >= 0.2 fs, by group-delay slack")
print("(slack = |centroid - implemented centroid| in samples).  implemented = %.2f dB\n" % WC_REF)
hdr = "  %-26s" % "taper family"
for sl in SLACK:
    hdr += "%11s" % ("unbounded" if sl > 100 else "%.1f" % sl)
print(hdr)
for name in FAM:
    row = "  %-26s" % name
    for sl in SLACK:
        v = best[name][sl][0]
        row += "%11s" % ("--" if v < -1e8 else "%.1f" % v)
    print(row)
print()
print("manuscript, matched delay: skew-normal 20.7, raised-cosine 21.9, exponential 21.6")
print("implemented delayed pair:  25.4")
print()
for name in FAM:
    v, prm = best[name][1e9]
    if prm:
        print("  %-26s unbounded best %6.2f dB | param %.2f mu %.2f s1 %.2f s2 %.2f centroid %.2f"
              % (name, v, *prm))
