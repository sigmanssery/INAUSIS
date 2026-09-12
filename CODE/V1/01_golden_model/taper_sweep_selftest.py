# -*- coding: utf-8 -*-
"""Self-test of the taper-sweep machinery.

The manuscript says "the no-taper case reproduces the shipped coefficient ROM to
0.1 dB, which is what makes the comparison trustworthy".  Run exactly that: the
same grid, the same constraints, the same scorer, with NO taper.  If it recovers
-25.4 dB then the machinery is sound and the taper numbers stand as measured.
"""
import numpy as np, os
from scipy.stats import norm

D = r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_package\INAUSIS_package\gowin_syn"
NF = 8192
L = 128
F = np.fft.rfftfreq(NF, 1.0)
I_STOP = F >= 0.2
n = np.arange(L)
T3 = 1.0 / np.sqrt(2.0)


def load(p):
    v = [int(x, 16) for x in open(p).read().split()]
    a = np.array([x - 65536 if x > 32767 else x for x in v], float) / 32768.0
    return [a[i * 256:(i + 1) * 256] for i in range(3)]


def mags(K):
    H = np.abs(np.fft.rfft(K, NF, axis=-1))
    return H / H.max(axis=-1, keepdims=True)


def edges_vec(Hn):
    above = Hn >= T3
    lo_i = above.argmax(axis=1)
    hi_i = Hn.shape[1] - 1 - above[:, ::-1].argmax(axis=1)
    r = np.arange(Hn.shape[0])
    a, b = Hn[r, lo_i - 1], Hn[r, lo_i]
    lo = F[lo_i - 1] + (T3 - a) / np.maximum(b - a, 1e-12) * (F[1] - F[0])
    a, b = Hn[r, hi_i], Hn[r, hi_i + 1]
    hi = F[hi_i] + (a - T3) / np.maximum(a - b, 1e-12) * (F[1] - F[0])
    return lo, hi


K = load(os.path.join(D, "dog_coeffs.mem"))
ref = K[0] - K[1]
Hr = mags(ref[None, :])
LO, HI = edges_vec(Hr)
LO, HI = float(LO[0]), float(HI[0])
WC_REF = 20 * np.log10(Hr[0][I_STOP].max())
A = np.abs(ref); CEN_REF = float((A * np.arange(256)).sum() / A.sum())
print("reference, straight from the ROM:  %.2f dB, edges %.5f/%.5f, centroid %.2f"
      % (WC_REF, LO, HI, CEN_REF))
print()

# ---- 1. rebuild the delayed pair from its design parameters, no taper -----
def pair(mu, s1, s2, taper=None, p=None):
    g1 = np.exp(-0.5 * ((n - mu) / s1) ** 2)
    g2 = np.exp(-0.5 * ((n - mu) / s2) ** 2)
    if taper == "skew":
        g1 = g1 * norm.cdf(p * (n - mu) / s1); g2 = g2 * norm.cdf(p * (n - mu) / s2)
    elif taper == "tukey":
        w = np.where(n < p, 0.5 * (1 - np.cos(np.pi * n / p)), 1.0); g1, g2 = g1 * w, g2 * w
    elif taper == "exp":
        w = 1.0 - np.exp(-n / p); g1, g2 = g1 * w, g2 * w
    return g1 / g1.sum() - g2 / g2.sum()


k = pair(5.3, 2.2, 8.8)
H = mags(k[None, :])
lo, hi = edges_vec(H)
print("SELF-TEST  designed delayed pair (mu 5.3, s1 2.2, s2 8.8), no taper:")
print("   %.2f dB   edges %.5f/%.5f   -> vs ROM: %+.2f dB, edges %+.1f%% / %+.1f%%"
      % (20 * np.log10(H[0][I_STOP].max()), lo[0], hi[0],
         20 * np.log10(H[0][I_STOP].max()) - WC_REF,
         100 * (lo[0] - LO) / LO, 100 * (hi[0] - HI) / HI))
print()

# ---- 2. best no-taper solution found by the same constrained grid ---------
S1 = np.arange(1.20, 6.01, 0.04)
S2 = np.arange(4.0, 24.01, 0.10)
MU = np.arange(0.0, 12.01, 0.1)
bw, bp = -1e9, None
for mu in MU:
    s1g, s2g = np.meshgrid(S1, S2, indexing="ij")
    m = s2g > s1g * 1.5
    s1v, s2v = s1g[m], s2g[m]
    g1 = np.exp(-0.5 * ((n[None, :] - mu) / s1v[:, None]) ** 2)
    g2 = np.exp(-0.5 * ((n[None, :] - mu) / s2v[:, None]) ** 2)
    g1 = g1 / g1.sum(axis=1, keepdims=True); g2 = g2 / g2.sum(axis=1, keepdims=True)
    Kc = g1 - g2
    Hn = mags(Kc)
    pk = F[Hn.argmax(axis=1)]
    sel = np.nonzero((pk > 0.025) & (pk < 0.09))[0]
    if not len(sel):
        continue
    lo, hi = edges_vec(Hn[sel])
    ok = (np.abs(lo - LO) <= 0.02 * LO) & (np.abs(hi - HI) <= 0.02 * HI)
    if not ok.any():
        continue
    ss = sel[ok]
    wc = 20 * np.log10(Hn[ss][:, I_STOP].max(axis=1))
    Aa = np.abs(Kc[ss]); cen = (Aa * n).sum(1) / Aa.sum(1)
    q = np.abs(cen - CEN_REF) <= 0.3
    if not q.any():
        continue
    j = int(np.argmax(np.where(q, wc, -1e9)))
    if wc[j] > bw:
        bw, bp = float(wc[j]), (mu, float(s1v[ss][j]), float(s2v[ss][j]), float(cen[j]))
print("SELF-TEST  best NO-TAPER solution the constrained grid can find:")
print("   %.2f dB  at mu %.2f s1 %.2f s2 %.2f centroid %.2f   -> %+.2f dB vs ROM"
      % (bw, *bp, bw - WC_REF))
print()
print("If both self-tests land within ~0.1 dB of the ROM, the machinery is sound and the")
print("taper figures measured against it are the real comparison.")
