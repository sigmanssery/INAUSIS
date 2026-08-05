#!/usr/bin/env python3
# tactile_map.py — real-time 4-corner tactile touch map + LDC curves for INAUSIS.
# Reads the top_dual UART (921600 8N1). Left: LIVE pressure heatmap + touch dot
# (force-weighted centroid of the 4 ADS corners). Right, split top/bottom:
#   top    = L  (inductance)     live curve   <- LDC1101 L_DATA
#   bottom = RP (parallel R)     live curve   <- LDC1101 RP_DATA
#
# UART lines (top_dual): "CH0: xxxx".."CH3: xxxx"  (ADS, signed 16-bit)
#                        "RP : xxxx"  "L  : xxxx"  (LDC, unsigned 16-bit)
#
# Corner -> ADC input -> UART channel  (from ads114s08_spi.v mux_table):
#   A = AIN4 = CH1      B = AIN5 = CH0
#   C = AIN0 = CH3      D = AIN1 = CH2
# Screen layout (A neighbours B and D; A is diagonal to C. Edit CORNERS to rotate):
#   A ----- D
#   |       |
#   B ----- C
#
# Robustness (so it doesn't jump when untouched):
#   * EMA smoothing per channel              (--smooth, default 0.3)
#   * AUTO threshold from the no-touch noise measured at calibration (--thresh 0)
#   * press 'r' in the window to RE-ZERO the baseline (use if it drifts)
#
# Usage:
#   python tactile_map.py --port COM6     (hands OFF during the ~2 s calibration)
#   --invert   if pressing makes a corner go DOWN (dot jumps to the OPPOSITE corner)
#   --thresh N force a fixed threshold instead of auto
#
# Needs: pyserial, numpy, matplotlib.
import argparse, json, os, re, time
import collections
import numpy as np
import serial
import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
from matplotlib.gridspec import GridSpec

# Screen positions (x,y in 0..1). Physical arrangement: A neighbours B and D,
# A is diagonal to C. Edit these coords to rotate/mirror; the heatmap
# interpolation and centroid both follow this dict automatically.
#   A --- D
#   |     |
#   B --- C
CORNERS = {'A': (0.0, 1.0), 'D': (1.0, 1.0), 'B': (0.0, 0.0), 'C': (1.0, 0.0)}
CH_OF   = {'A': 1, 'B': 0, 'C': 3, 'D': 2}          # corner -> UART CHx
AIN_OF  = {'A': 4, 'B': 5, 'C': 0, 'D': 1}          # corner -> ADS AIN pin

LDC_HIST = 400          # samples kept in the L / RP scrolling curves (~4 s @10ms)


def to_s16(h):
    v = int(h, 16)
    return v - 65536 if v >= 32768 else v


def main():
    ap = argparse.ArgumentParser(description="INAUSIS real-time tactile map + LDC curves")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--invert", action="store_true",
                    help="force = baseline - value (FSR decreases on press)")
    ap.add_argument("--cal", type=int, default=300, help="no-touch baseline frames")
    ap.add_argument("--thresh", type=float, default=0.0,
                    help="min total force to show a touch; 0 = auto from noise")
    ap.add_argument("--thresh-k", type=float, default=1.5,
                    help="auto-threshold margin above the no-touch p99 "
                         "(lower = more sensitive, more false touches)")
    ap.add_argument("--dead", type=float, default=3.0,
                    help="per-corner dead zone in sigmas of that corner's noise; "
                         "keeps the resting F at ~0 (0 = off)")
    ap.add_argument("--smooth", type=float, default=0.3, help="EMA alpha (0..1, lower=smoother)")
    ap.add_argument("--rail", type=float, default=20000.0,
                    help="reject |code|>rail as a glitch (ADS bring-up intermittently reads ~+FS 0x7F8D)")
    ap.add_argument("--rp-smooth", type=float, default=0.2,
                    help="EMA alpha for the RP curve (dual emits raw RP; lower=smoother)")
    ap.add_argument("--grid", type=int, default=120)
    ap.add_argument("--calibrate", action="store_true",
                    help="measure each corner's POLARITY and GAIN (press each in turn) "
                         "and save them. Measured 2026-07-30: A/C respond NEGATIVE, B/D "
                         "POSITIVE, and amplitudes span 54x (C=-44 vs B=+2384) — so a "
                         "single global --invert leaves two corners contributing nothing "
                         "and drags the centroid toward B")
    ap.add_argument("--cal-file", default=None,
                    help="corner polarity/gain file (default: tactile_cal.json beside "
                         "this script). Auto-loaded when present")
    ap.add_argument("--no-cal", action="store_true", help="ignore any saved calibration")
    ap.add_argument("--raw", nargs="?", type=float, const=0.2, default=0.0,
                    metavar="SEC",
                    help="also print the live values in this console (the COM port "
                         "can only be held by one program, so read_uart.ps1 can't run "
                         "alongside). Optional arg = print interval, default 0.2 s")
    a = ap.parse_args()

    sp = serial.Serial(a.port, a.baud, timeout=0.05)
    pat_ch = re.compile(rb'CH([0-3]):\s*([0-9A-Fa-f]{4})')
    pat_rp = re.compile(rb'RP\s*:\s*([0-9A-Fa-f]{4})')
    pat_l  = re.compile(rb'\bL\s+:\s*([0-9A-Fa-f]{4})')
    latest = [0, 0, 0, 0]
    seen = [False] * 4

    ldc = {'rp': None, 'l': None}                 # smoothed RP, last L
    lhist  = collections.deque(maxlen=LDC_HIST)
    rphist = collections.deque(maxlen=LDC_HIST)

    drops = {'ok': 0, 'bad': 0}
    def read_pending(maxlines=400):
        n = 0
        while sp.in_waiting and n < maxlines:
            line = sp.readline()
            m = pat_ch.search(line)
            if m:
                ch = int(m.group(1)); v = to_s16(m.group(2).decode())
                if abs(v) < a.rail:                 # drop the intermittent ~+FS glitch reads
                    latest[ch] = v; seen[ch] = True; drops['ok'] += 1
                else:
                    drops['bad'] += 1
                n += 1; continue
            m = pat_rp.search(line)
            if m:
                rp = int(m.group(1), 16)
                if rp not in (0x0000, 0xFFFF):      # 0000/FFFF = update transient / not ready
                    ldc['rp'] = rp if ldc['rp'] is None else ldc['rp'] + a.rp_smooth*(rp - ldc['rp'])
                    rphist.append(ldc['rp'])
                n += 1; continue
            m = pat_l.search(line)
            if m:
                lv = int(m.group(1), 16)
                if lv not in (0x0000, 0xFFFF):
                    ldc['l'] = lv; lhist.append(lv)
                n += 1; continue
        return n

    # ---- no-touch baseline + noise envelope ----
    print(f"[{a.port} @{a.baud}] calibrating baseline — KEEP HANDS OFF ...")
    frames = []                      # list of [v0,v1,v2,v3] full cycles
    t0 = time.time()
    while len(frames) < a.cal and time.time() - t0 < 12:
        read_pending()
        if all(seen):
            frames.append(list(latest))
            for i in range(4):
                seen[i] = False
        time.sleep(0.002)
    if len(frames) < 5:
        print("!! almost no data — check bitstream/wiring (CHx not arriving)"); return
    F = np.array(frames, float)
    base = {c: float(F[:, CH_OF[c]].mean()) for c in CORNERS}

    # Auto threshold must describe the signal the UI ACTUALLY shows: the runtime
    # force comes from the EMA-smoothed channels, so replay the same EMA over the
    # calibration frames before measuring the no-touch envelope. (Measuring RAW
    # frames overstates the noise by ~1/sqrt(alpha/(2-alpha)) — 2.4x at alpha=0.3.)
    Fs = np.empty_like(F)
    _e = F[0].astype(float).copy()
    for i, row in enumerate(F):
        _e += a.smooth * (row - _e)
        Fs[i] = _e
    Fs = Fs[len(Fs)//5:]                       # drop the EMA warm-up
    noise = {c: float(Fs[:, CH_OF[c]].std()) for c in CORNERS}

    # ---- per-corner POLARITY + GAIN ------------------------------------------
    # Corners do not respond alike: on this pad A/C go negative and B/D positive
    # on press, with a 54x amplitude spread. Since force is max(0, deviation),
    # a single global --invert silently zeroes whichever polarity it doesn't
    # match, so those corners never contribute and the centroid is pulled toward
    # the strongest one. sgn/gain normalise both out.
    cal_path = a.cal_file or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                          "tactile_cal.json")
    sgn = {c: 1.0 for c in CORNERS}
    gain = {c: 1.0 for c in CORNERS}

    if a.calibrate:
        print("\n--- corner calibration: press ONE corner at a time, firmly ---")
        resp = {}
        for c in sorted(CORNERS):
            input(f"  press and HOLD corner {c}, then hit ENTER (keep holding) ... ")
            sp.reset_input_buffer()
            vals, t0 = [], time.time()
            while time.time() - t0 < 1.5:
                read_pending()
                vals.append(latest[CH_OF[c]])
                time.sleep(0.005)
            resp[c] = float(np.median(vals)) - base[c]
            print(f"      {c}: response = {resp[c]:+.0f} counts")
        ref = max(abs(v) for v in resp.values()) or 1.0
        for c in CORNERS:
            sgn[c] = 1.0 if resp[c] >= 0 else -1.0
            gain[c] = ref / max(abs(resp[c]), 1.0)
        with open(cal_path, "w", encoding="utf-8") as fh:
            json.dump({"response": resp,
                       "sign": sgn, "gain": gain}, fh, indent=2)
        print(f"  saved -> {cal_path}")
        print("  NOTE: normalising a weak corner amplifies its noise too — that is "
              "inherent, the alternative is a centroid biased toward the strong corner.")
    elif not a.no_cal and os.path.exists(cal_path):
        try:
            with open(cal_path, encoding="utf-8") as fh:
                d = json.load(fh)
            sgn.update({k: float(v) for k, v in d.get("sign", {}).items() if k in CORNERS})
            gain.update({k: float(v) for k, v in d.get("gain", {}).items() if k in CORNERS})
            print(f"corner calibration loaded from {cal_path}")
        except Exception as e:
            print(f"!! could not read {cal_path} ({e}) — using sign=+1 gain=1")

    # Per-corner DEAD ZONE. The force is a half-wave-rectified sum, so even
    # zero-mean noise gives a positive resting F (E ~= sum of sigma/sqrt(2pi)).
    # Ignoring deviations under dead*sigma pins the resting F at ~0 while costing
    # a real press only a few counts out of several hundred.
    # dead zone lives in the SAME normalised units as the force, so it scales with gain
    dz = {c: a.dead * noise[c] * gain[c] for c in CORNERS}

    def dev(raw, c):
        """raw ADC code -> polarity-corrected, gain-normalised deviation."""
        d = (raw - base[c]) * sgn[c] * gain[c]
        return -d if a.invert else d

    def tot_force_row(row):
        return sum(max(0.0, dev(row[CH_OF[c]], c) - dz[c]) for c in CORNERS)

    # Use a high percentile rather than max(), so one glitch can't inflate it.
    noise_tot = np.array([tot_force_row(r) for r in Fs])
    auto_thr = float(a.thresh_k * np.percentile(noise_tot, 99) + 2)
    thr = a.thresh if a.thresh > 0 else auto_thr
    print("per-corner  baseline / noise(std, smoothed) / dead zone / polarity / gain:")
    for c in sorted(CORNERS):
        flag = "" if gain[c] == 1.0 and sgn[c] == 1.0 else "  <-calibrated"
        print(f"   {c}  CH{CH_OF[c]} AIN{AIN_OF[c]:>2}:  base={base[c]:9.0f}   "
              f"noise={noise[c]:7.2f}   dead={dz[c]:6.2f}   "
              f"sign={sgn[c]:+.0f}  gain={gain[c]:6.2f}{flag}")
    if all(g == 1.0 for g in gain.values()):
        print("   (no corner calibration — run once with --calibrate; on this pad A/C "
              "and B/D have OPPOSITE polarity, so half the corners read as zero force)")
    print(f"no-touch total-force (smoothed): p99={np.percentile(noise_tot,99):.0f} "
          f"mean={noise_tot.mean():.0f} max={noise_tot.max():.0f}"
          f"  -> threshold={thr:.0f}{'  (auto)' if a.thresh<=0 else ''}")
    if ldc['rp'] is not None or ldc['l'] is not None:
        _rp = ('0x%04X' % int(ldc['rp'])) if ldc['rp'] is not None else '--'
        _l  = ('0x%04X' % int(ldc['l']))  if ldc['l']  is not None else '--'
        print(f"LDC: RP={_rp}  L={_l}   (curves on the right)")
    else:
        print("LDC: no RP/L lines seen yet (curves will fill once they arrive)")
    _tot = drops['ok'] + drops['bad']
    if _tot:
        print(f"glitch reads rejected (|code|>{a.rail:.0f}): {drops['bad']}/{_tot} = "
              f"{100*drops['bad']/_tot:.0f}%   <- ADS bring-up read artifact, not your wiring")
    print("\nsettings — what each one does (change with the flag in [ ]):")
    print(f"  threshold = {thr:.0f}   [--thresh]  min TOTAL force to count as a touch; below this shows 'no touch'")
    print(f"  thresh-k  = {a.thresh_k:.2f}   [--thresh-k] auto-threshold margin; LOWER = more sensitive (try 1.0)")
    print(f"  dead      = {a.dead:.1f}    [--dead]    per-corner dead zone in sigmas; keeps resting F ~0 (0 = off)")
    print(f"  smooth    = {a.smooth:.2f}   [--smooth]  EMA smoothing 0..1; lower = steadier but slower to react")
    print(f"  rail      = {a.rail:.0f}   [--rail]    reject any |reading| > this as a bad ADS read (glitch)")
    print(f"  invert    = {'ON' if a.invert else 'off'}   [--invert]  turn ON if pressing makes a corner value go DOWN")
    print(f"  cal       = {a.cal}   [--cal]     no-touch samples used to learn the zero baseline")
    print("\nready — press the pad.   keys: [r]=re-zero baseline   (close the window to quit)")

    ema = [float(F[:, i].mean()) for i in range(4)]   # seed EMA at baseline

    # ---- figure: map (left) + L/RP curves (right, top/bottom) ----
    fig = plt.figure(figsize=(10.0, 6.2))
    try:
        fig.canvas.manager.set_window_title("INAUSIS tactile map + LDC")
    except Exception:
        pass
    gs = GridSpec(2, 2, width_ratios=[2.3, 1.0],
                  left=0.03, right=0.965, top=0.94, bottom=0.07, hspace=0.32, wspace=0.16)
    ax  = fig.add_subplot(gs[:, 0])     # map spans both rows on the left
    axL  = fig.add_subplot(gs[0, 1])    # L  curve, top-right
    axRP = fig.add_subplot(gs[1, 1])    # RP curve, bottom-right

    g = a.grid
    X, Y = np.meshgrid(np.linspace(0, 1, g), np.linspace(0, 1, g))
    im = ax.imshow(np.zeros((g, g)), origin='lower', extent=[0, 1, 0, 1],
                   cmap='inferno', vmin=0, vmax=300, aspect='equal')
    dot, = ax.plot([], [], 'o', ms=26, mfc='none', mec='cyan', mew=3)
    txts = {}
    for c, (x, y) in CORNERS.items():
        ax.plot(x, y, 's', ms=11, color='white', mec='0.3')
        txts[c] = ax.text(x, y + (0.05 if y < 0.5 else -0.085), c,
                          color='white', ha='center', va='center', fontsize=13, weight='bold')
    ax.set_xlim(-0.06, 1.06); ax.set_ylim(-0.06, 1.06)
    ax.set_xticks([]); ax.set_yticks([])
    for s in ax.spines.values():
        s.set_visible(False)
    title = ax.set_title("press the pad", fontsize=12, color='0.4')

    # LDC curves (top = L, bottom = RP)
    lineL,  = axL.plot([],  [], '-', color='tab:cyan',   lw=1.6)
    lineRP, = axRP.plot([], [], '-', color='tab:orange', lw=1.6)
    for axx, name in ((axL, "L (inductance)"), (axRP, "RP (parallel R)")):
        axx.set_title(name, fontsize=10, color='0.5')
        axx.grid(True, alpha=0.25); axx.tick_params(labelsize=8)
        axx.margins(x=0)

    state = {'thr': thr, 't_raw': 0.0}
    if a.raw:
        print(f"\nraw echo ON (every {a.raw:.2f}s) — corner values are baseline-"
              f"subtracted, dead zone applied; CHx are the signed ADC codes\n")

    def on_key(ev):
        if ev.key == 'r':
            for c in CORNERS:
                base[c] = ema[CH_OF[c]]
            print("re-zeroed baseline:", {c: round(base[c], 1) for c in CORNERS})
    fig.canvas.mpl_connect('key_press_event', on_key)

    def forces():
        # same polarity/gain/dead-zone the threshold was calibrated with
        return {c: max(0.0, dev(ema[CH_OF[c]], c) - dz[c]) for c in CORNERS}

    def upd_curve(axx, line, hist, name):
        if not hist:
            return
        y = list(hist)
        line.set_data(range(len(y)), y)
        axx.set_xlim(0, max(len(y), 10))
        lo, hi = min(y), max(y)
        pad = max((hi - lo) * 0.20, 2.0)
        axx.set_ylim(lo - pad, hi + pad)
        cur = int(round(y[-1]))
        axx.set_title(f"{name} = 0x{cur:04X} ({cur})", fontsize=10, color='0.5')

    def update(_):
        read_pending()
        al = a.smooth
        for i in range(4):
            ema[i] += al * (latest[i] - ema[i])
        f = forces()
        # bilinear field derived from each corner's actual position in CORNERS
        field = np.zeros_like(X)
        for cc, (cx, cy) in CORNERS.items():
            field = field + f[cc] * (X if cx >= 0.5 else (1 - X)) * (Y if cy >= 0.5 else (1 - Y))
        im.set_data(field)
        im.set_clim(0, max(field.max(), 100.0))   # auto-scale to the field, not the threshold
        tot = sum(f.values())
        if tot > state['thr']:
            cx = sum(CORNERS[c][0] * f[c] for c in CORNERS) / tot
            cy = sum(CORNERS[c][1] * f[c] for c in CORNERS) / tot
            dot.set_data([cx], [cy])
            title.set_text(f"touch @ ({cx:.2f}, {cy:.2f})   F={tot:.0f}")
        else:
            dot.set_data([], [])
            title.set_text(f"no touch   (F={tot:.0f} < {state['thr']:.0f})")
        for c in CORNERS:
            txts[c].set_text(f"{c}\n{f[c]:.0f}")
        upd_curve(axL,  lineL,  lhist,  "L")
        upd_curve(axRP, lineRP, rphist, "RP")

        if a.raw:
            now = time.time()
            if now - state['t_raw'] >= a.raw:
                state['t_raw'] = now
                ch_s = "  ".join(f"CH{i}:{latest[i]:6d}" for i in range(4))
                cor_s = " ".join(f"{c}={f[c]:6.0f}" for c in "ABCD" if c in CORNERS)
                rp_s = "----" if ldc['rp'] is None else f"{int(ldc['rp']):5d}"
                l_s = "----" if ldc['l'] is None else f"{ldc['l']:5d}"
                print(f"{ch_s} | {cor_s} | RP:{rp_s} L:{l_s} | "
                      f"F={tot:7.1f}/{state['thr']:.0f} "
                      f"{'TOUCH' if tot > state['thr'] else '     '}")
        return [im, dot, title, lineL, lineRP] + list(txts.values())

    ani = FuncAnimation(fig, update, interval=50, blit=False, cache_frame_data=False)
    plt.show()
    sp.close()


if __name__ == "__main__":
    main()
