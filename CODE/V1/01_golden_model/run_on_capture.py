#!/usr/bin/env python3
"""
run_on_capture.py — feed a REAL hardware capture through the TTCGS golden model.

Everything validated so far is raw front-end; the DoG / z-score chain has only
ever seen the synthetic test signal. This runs it on actual sensor data captured
by gowin_syn/log_dual.py, with no hardware and no RTL touched.

SAMPLE-RATE CAVEAT (important, printed at run time):
the paper's sigmas 2/8/85 samples are defined at 1000 SPS, i.e. time constants
2 / 8 / 85 ms. The dual UART bursts at ~100 SPS, so sigma1 lands at 0.2 samples —
the reflex band simply is not representable in this data (its 20.7-116 Hz passband
is above the 50 Hz Nyquist). Sigmas are rescaled here to preserve the TIME
constants, and any band that comes out under ~1 sample is reported as unusable
rather than silently producing garbage. The fast band needs the 1 kHz path
inside ttcgs_board.

Usage:
  python run_on_capture.py <csv> --ch rp
  python run_on_capture.py <csv> --ch A --quiet-s 3
  python run_on_capture.py <csv> --ch l --plot out.png
"""
import argparse, csv, os, sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ttcgs_golden_model import (causal_gaussian, causal_fir_fast, zscore_flag,
                                N_TAPS, SIGMAS, ZSCORE_N, ROC_K)

# corner -> UART channel (from ads114s08_spi.v mux_table)
CH_OF = {"A": 1, "B": 0, "C": 3, "D": 2}
RAIL = 20000


def load(path, ch):
    t, v = [], []
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            try:
                tt = float(r["t_s"])
            except (ValueError, KeyError):
                continue
            if ch in CH_OF:
                s = r.get(f"ch{CH_OF[ch]}", "")
                if not s:
                    continue
                x = int(s)
                if abs(x) > RAIL:            # railed ADS read -> hold last
                    continue
            else:
                s = r.get(ch, "")
                if not s:
                    continue
                x = int(s)
                if x in (0, 65535):
                    continue
            t.append(tt); v.append(float(x))
    return np.asarray(t), np.asarray(v)


def main():
    ap = argparse.ArgumentParser(description="run the TTCGS golden model on a real capture")
    ap.add_argument("csv")
    ap.add_argument("--ch", default="rp",
                    help="rp | l | A | B | C | D   (corner letters are the ADS channels)")
    ap.add_argument("--quiet-s", type=float, default=2.0,
                    help="seconds at the start treated as at-rest, for baseline + noise")
    ap.add_argument("--sigma-mode", choices=("samples", "time"), default="samples",
                    help="samples: use 2/8/85 as literal sample counts, exactly as the "
                         "RTL does at its own rate — tests the ALGORITHM on real data, "
                         "at a slower physical band than the paper's. "
                         "time: rescale to keep the paper's 2/8/85 ms, which the ~100 SPS "
                         "capture cannot represent for the fast bands.")
    ap.add_argument("--zn", type=float, default=ZSCORE_N, help="z threshold (sigmas)")
    ap.add_argument("--eps", type=float, nargs=3, default=None,
                    metavar=("EPS1", "EPS2", "EPS3"),
                    help="per-band epsilon added to the denominator: "
                         "z = feature/(sigma+eps), for DoG_fast / DoG_slow / G_s3. "
                         "Cheaper than a floor in RTL (the comparison is |f| > N*sigma, "
                         "so this is just +N*eps on the threshold) and continuous — no "
                         "clamp discontinuity. Per band because the three sigmas differ ~10x")
    ap.add_argument("--sigma-floor", type=float, default=0.0, metavar="LSB",
                    help="clamp the calibrated noise sigma to at least this many ADC "
                         "counts. On a quantisation-limited channel the smoothed G_s3 "
                         "noise collapses to ~0.01 counts, so 1 LSB of baseline drift "
                         "clears a 3-sigma threshold and the flag latches on. 0 = off")
    ap.add_argument("--debounce", type=int, default=3, help="consecutive samples to confirm")
    ap.add_argument("--plot", default=None, help="write a PNG here")
    ap.add_argument("--median", type=int, default=0, metavar="N",
                    help="N-tap median filter on the raw channel before the DoG "
                         "chain (3 = what top_dual already does in RTL for RP). "
                         "Single-sample spikes make DoG_fast fire on nothing; a "
                         "median kills them outright and costs a real multi-sample "
                         "event only a little of its peak")
    ap.add_argument("--start-s", type=float, default=None)
    ap.add_argument("--end-s", type=float, default=None,
                    help="analyse only this window. Use it when a channel dies partway "
                         "(dropped railed samples get INTERPOLATED ACROSS, which fabricates "
                         "data — the drop rate is reported below)")
    a = ap.parse_args()

    t, v = load(a.csv, a.ch)
    n_raw = len(t)
    if a.start_s is not None or a.end_s is not None:
        lo = a.start_s if a.start_s is not None else -1e9
        hi = a.end_s if a.end_s is not None else 1e9
        m = (t >= lo) & (t <= hi)
        t, v = t[m], v[m]
    if len(v) < 200:
        print(f"!! only {len(v)} usable samples — nothing to do"); return
    dt = np.median(np.diff(t))
    fs = 1.0 / dt
    print(f"{os.path.basename(a.csv)}   channel={a.ch}")
    print(f"  samples={len(v)}  span={t[0]:.2f}..{t[-1]:.2f}s  fs={fs:.1f} SPS")

    # resample onto a uniform grid (the UART timing jitters a little)
    if a.median > 1:
        k = a.median | 1                       # force odd
        pad = np.pad(v, (k//2, k//2), mode="edge")
        v = np.array([np.median(pad[i:i+k]) for i in range(len(v))])
        print(f"  {k}-tap median applied to the raw channel")
    grid = np.arange(t[0], t[-1], dt)
    x = np.interp(grid, t, v)
    gaps = np.diff(t)
    lost = float(np.sum(gaps[gaps > 3 * dt]))
    if lost > 0.05 * (t[-1] - t[0]):
        print(f"  !! {100*lost/(t[-1]-t[0]):.0f}% of this window is GAPS (railed/invalid "
              f"samples were dropped) and is being interpolated across — the features "
              f"there are fabricated. Restrict with --end-s / --start-s.")

    # Remove the at-rest baseline. The golden model's synthetic signal sits at 0;
    # a real sensor sits on a large DC offset (RP ~42000), which would make the
    # "abs" G_s3 flag fire permanently. Referencing to the no-touch level is what
    # the sensor baseline means physically.
    nq = int(a.quiet_s * fs)
    base = float(np.mean(x[:nq]))
    x = x - base
    print(f"  baseline (first {a.quiet_s:g}s) = {base:.1f}, subtracted")

    if a.sigma_mode == "samples":
        sig_s = list(SIGMAS)          # literal sample counts, exactly like the RTL
        usable = [True] * 3
        print(f"\n  sigma mode = SAMPLES (as the RTL applies them). At {fs:.0f} SPS these "
              f"are time constants "
              + ", ".join(f"{s*1000/fs:.0f}ms" for s in SIGMAS)
              + f"\n  -> tests the ALGORITHM on real data, but at a SLOWER band than the "
                f"paper's {'/'.join(f'{s:g}' for s in SIGMAS)} ms. Not a validation of the "
                f"paper's reflex band.")
    else:
        scale = fs / 1000.0
        sig_s = [s * scale for s in SIGMAS]
        print(f"\n  sigma mode = TIME (keep the paper's ms): "
              + ", ".join(f"{s:g}ms->{ss:.2f} samp" for s, ss in zip(SIGMAS, sig_s)))
        usable = [ss >= 1.0 for ss in sig_s]
        for s, ss, u in zip(SIGMAS, sig_s, usable):
            if not u:
                print(f"  !! sigma={s:g} ms -> {ss:.2f} samples: NOT representable at "
                      f"{fs:.0f} SPS (needs the 1 kHz path inside ttcgs_board)")

    kers = [causal_gaussian(max(ss, 0.5), N_TAPS) for ss in sig_s]
    G1, G2, G3 = (causal_fir_fast(x, k) for k in kers)
    feats = {"DoG_fast": (G1 - G2, "roc", usable[0] and usable[1]),
             "DoG_slow": (G2 - G3, "roc", usable[1] and usable[2]),
             "G_s3":     (G3,      "abs", usable[2])}

    print(f"\n  noise calibrated on the first {a.quiet_s:g}s ({nq} samples, sensor at rest)")
    print(f"  z threshold={a.zn}  debounce={a.debounce}  ROC lag k={ROC_K}\n")
    print(f"  {'feature':10s} {'usable':7s} {'noise sd':>10s} {'|z| max':>9s} "
          f"{'FP@rest':>8s} {'flagged':>8s}  events")

    results = {}
    eps_of = dict(zip(("DoG_fast", "DoG_slow", "G_s3"), a.eps)) if a.eps else {}
    for name, (feat, mode, ok) in feats.items():
        if mode == "roc":
            d = feat.astype(float).copy()
            d[ROC_K:] = feat[ROC_K:] - feat[:-ROC_K]
            sigma = float(np.std(d[:nq]))
        else:
            sigma = float(np.std(feat[:nq]))
        if a.sigma_floor > 0:
            sigma = max(sigma, a.sigma_floor)
        sigma += eps_of.get(name, 0.0)      # z = feature / (sigma + eps)
        z, flag = zscore_flag(feat, sigma, N=a.zn, mode=mode,
                              k=ROC_K, debounce=a.debounce)
        results[name] = (feat, z, flag, sigma, ok)
        # group flags into events
        ev, i = [], 0
        f = flag.astype(int)
        while i < len(f):
            if f[i]:
                j = i
                while j + 1 < len(f) and f[j + 1]:
                    j += 1
                ev.append((grid[i], grid[j] - grid[i])); i = j + 1
            else:
                i += 1
        zmax = float(np.max(np.abs(z[nq:]))) if len(z) > nq else 0.0
        # FALSE POSITIVES: how often it fires while the sensor is demonstrably at
        # rest. This, not the overall flagged%, says whether calibration is sane —
        # a sustained press SHOULD keep G_s3 flagged for its whole duration.
        fp = 100 * flag[:nq].mean()
        print(f"  {name:10s} {'yes' if ok else 'NO':7s} {sigma:10.2f} {zmax:9.1f} "
              f"{fp:7.2f}% {100*flag.mean():7.1f}%  {len(ev)}")
        if ev:
            head = "  ".join(f"{s:.2f}s({d*1000:.0f}ms)" for s, d in ev[:6])
            print(f"             first events: {head}")

    if a.plot:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        fig, ax = plt.subplots(4, 1, figsize=(11, 9), sharex=True)
        ax[0].plot(grid, x, lw=0.8, color="0.3"); ax[0].set_ylabel(a.ch)
        ax[0].set_title(f"{os.path.basename(a.csv)} — {a.ch} @ {fs:.0f} SPS")
        for k, name in enumerate(("DoG_fast", "DoG_slow", "G_s3")):
            feat, z, flag, sigma, ok = results[name]
            axx = ax[k + 1]
            axx.plot(grid, z, lw=0.8)
            axx.axhline(a.zn, color="r", ls=":", lw=0.8)
            axx.axhline(-a.zn, color="r", ls=":", lw=0.8)
            axx.fill_between(grid, -1, 1, where=flag, color="r", alpha=0.25,
                             transform=axx.get_xaxis_transform())
            axx.set_ylabel(f"z {name}" + ("" if ok else "  (N/A)"))
        ax[-1].set_xlabel("time (s)")
        fig.tight_layout(); fig.savefig(a.plot, dpi=110)
        print(f"\n  plot -> {a.plot}")


if __name__ == "__main__":
    main()
