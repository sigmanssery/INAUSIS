#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
fixed_point_shipped.py  --  fixed-point cost of the SHIPPED DoG datapath.

Why this exists
---------------
`fixed_point_analysis.py` answers the same question against
`ttcgs_golden_model.py`, whose kernels are SIGMAS = [2.0, 8.0, 85.0] built by
`causal_gaussian` -- one-sided, no offset, fs = 1000.  That is the form the
paper examines and *rejects*; the board carries a delayed pair at sigma 2.2 /
8.8 / 85 with a common offset, clocked at 689.40 frames/s.  So the older
script's SNR figures describe a filter that is not on the device, and the two
numbers the manuscript quoted (55.7 / 59.1 dB) do not even match that script's
own Q15 row -- 55.7 is its Q12 entry for DoG_fast.

This script instead:
  1. reads the 768 Q15 words actually programmed into the coefficient ROM,
  2. recovers each kernel's offset and width by a least-squares Gaussian fit,
  3. builds the ideal float design from those recovered parameters,
  4. runs both through the datapath exactly as `dog_fir_multi.v` does it --
     39-bit accumulator, `acc >>> 15`, sat16, and the band difference taken
     *after* each smoothed stream is saturated to 16 bits,
  5. drives it with a real recording rather than a synthetic test signal,
  6. reports the SNR of the fixed-point features against the float ones, and
     how much headroom the 39-bit accumulator actually had.

The comparison that matters is float-ideal vs fixed-point: both see the same
input samples, so the difference is the arithmetic and nothing else.
"""
import io
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
PKG = os.path.dirname(HERE)
ROM = os.path.join(PKG, "gowin_syn", "dog_coeffs.mem")
REC = os.path.join(PKG, "gowin_syn", "2026-09-10_P1_stable_touch300s_raw.csv")

N_TAPS = 256
FRAC = 15
ACC_BITS = 39            # `reg signed [38:0] acc`
FPS = 689.40


# ---------------------------------------------------------------- ROM -----
def load_rom(path):
    """768 16-bit two's-complement hex words: sigma1[0..255] then s2 then s3."""
    w = [int(t, 16) for t in io.open(path).read().split()]
    if len(w) != 3 * N_TAPS:
        sys.exit("ROM has %d words, expected %d" % (len(w), 3 * N_TAPS))
    q = np.array([v - 0x10000 if v & 0x8000 else v for v in w], dtype=np.int64)
    return q.reshape(3, N_TAPS)


def fit_gaussian(k):
    """Least-squares (amplitude, mu, sigma) for a sampled Gaussian.

    Taking logs turns it into a quadratic in n, so this is a linear solve on
    the taps that carry enough amplitude to be informative -- no optimiser and
    no starting guess, which keeps the check independent of the design script.
    """
    n = np.arange(len(k), dtype=np.float64)
    y = k.astype(np.float64)
    m = y > 0.02 * y.max()               # taps where log is meaningful
    c = np.polyfit(n[m], np.log(y[m]), 2)
    sigma = np.sqrt(-1.0 / (2.0 * c[0]))
    mu = c[1] * sigma ** 2
    return mu, sigma


def ideal_float(mu, sigma):
    n = np.arange(N_TAPS, dtype=np.float64)
    k = np.exp(-0.5 * ((n - mu) / sigma) ** 2)
    return k / k.sum()                   # unit DC gain, the design intent


# ----------------------------------------------------------- datapath -----
def sat16(v):
    return np.clip(v, -32768, 32767)


def fir_fixed(x_int, q):
    """Integer MAC into a 39-bit accumulator, then `sat16(acc >>> FRAC)`.

    Returns the saturated 16-bit stream and the largest |acc| seen, so the
    accumulator-width claim is checked on the same data rather than assumed.
    """
    acc = np.convolve(x_int, q)[:len(x_int)]        # exact in int64
    lim = 1 << (ACC_BITS - 1)
    if np.abs(acc).max() >= lim:
        sys.exit("!! 39-bit accumulator OVERFLOWS on this input")
    return sat16(acc >> FRAC), int(np.abs(acc).max())


def fir_float(x, k):
    return np.convolve(x, k)[:len(x)]


def snr_db(ref, test):
    e = test - ref
    return 20.0 * np.log10(np.sqrt((ref ** 2).mean()) /
                           max(np.sqrt((e ** 2).mean()), 1e-12))


# --------------------------------------------------------------- main -----
def main():
    q = load_rom(ROM)
    print("=" * 70)
    print("1. WHAT IS ACTUALLY IN THE COEFFICIENT ROM  (%s)" % os.path.basename(ROM))
    print("=" * 70)
    par = []
    for i, k in enumerate(q):
        mu, sg = fit_gaussian(k)
        par.append((mu, sg))
        print("   kernel %d: offset %6.3f  sigma %7.3f   sum %6d (unit = %d)"
              % (i + 1, mu, sg, k.sum(), 1 << FRAC))
    # Only the band-pass pair is displaced.  G_s3 is the level channel and is
    # deliberately left at zero offset, so averaging all three would hide the
    # very thing being checked.
    fast_off = [par[0][0], par[1][0]]
    if abs(fast_off[0] - fast_off[1]) > 0.05:
        print("   !! kernels 1 and 2 do NOT share an offset (%.3f vs %.3f):"
              % tuple(fast_off))
        print("      the band-pass pair is not a common displacement")
    else:
        print("   -> kernels 1 and 2 share an offset of %.3f samples: the"
              % np.mean(fast_off))
        print("      delayed pair. Kernel 3 (the level channel) sits at %.3f,"
              % par[2][0])
        print("      undisplaced, as designed. ttcgs_golden_model.py builds")
        print("      the one-sided form for all three and is NOT this filter.")

    print()
    print("=" * 70)
    print("2. INPUT")
    print("=" * 70)
    if not os.path.exists(REC):
        sys.exit("missing recording: %s" % REC)
    d = np.genfromtxt(REC, delimiter=",", names=True)
    x = d["d12"].astype(np.int64)                    # raw converter channel
    ts = d["ts"].astype(np.int64)
    step = np.diff(ts)
    print("   %s" % os.path.basename(REC))
    print("   %d frames, %.1f s at %.2f fps; frame counter steps by one: %s"
          % (len(x), len(x) / FPS, FPS, bool((step == 1).all())))
    print("   raw range %d .. %d counts" % (x.min(), x.max()))

    print()
    print("=" * 70)
    print("3. FIXED POINT vs THE IDEAL FLOAT DESIGN, ON THAT RECORDING")
    print("=" * 70)
    xf = x.astype(np.float64)
    gi, gf, head = [], [], []
    for (mu, sg), qk in zip(par, q):
        s, h = fir_fixed(x, qk)
        gi.append(s)
        gf.append(fir_float(xf, ideal_float(mu, sg)))
        head.append(h)

    warm = N_TAPS                                     # discard the fill
    rows = [("G_s1", gi[0], gf[0]),
            ("G_s2", gi[1], gf[1]),
            ("G_s3", gi[2], gf[2]),
            # the band difference is taken AFTER each stream is saturated
            ("DoG_fast", sat16(gi[0] - gi[1]), gf[0] - gf[1]),
            ("DoG_slow", sat16(gi[1] - gi[2]), gf[1] - gf[2])]
    print("   %-10s %12s %11s %10s" % ("", "signal rms", "err rms", "SNR (dB)"))
    out = {}
    for name, a, b in rows:
        a = a[warm:].astype(np.float64)
        b = b[warm:]
        s = snr_db(b, a)
        out[name] = s
        print("   %-10s %12.2f %11.3f %10.1f"
              % (name, np.sqrt((b ** 2).mean()), np.sqrt(((a - b) ** 2).mean()), s))

    print()
    print("   accumulator: widest |acc| = %d, i.e. %.1f bits of %d used"
          % (max(head), np.log2(max(head)) + 1, ACC_BITS))
    print("   headroom to overflow: %.1f bits"
          % (ACC_BITS - 1 - np.log2(max(head))))

    print()
    print("=" * 70)
    print("4. WHAT THE PAPER SHOULD SAY")
    print("=" * 70)
    print("   Q15 coefficients with a %d-bit accumulator preserve the features at"
          % ACC_BITS)
    print("   %.1f dB SNR for DoG_fast and %.1f dB for DoG_slow."
          % (out["DoG_fast"], out["DoG_slow"]))
    print("   (manuscript had 55.7 / 59.1, computed on the one-sided model)")


if __name__ == "__main__":
    main()
