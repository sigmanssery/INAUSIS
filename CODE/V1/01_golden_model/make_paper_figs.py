"""make_paper_figs.py — TTCGS paper Figs 4 and 5 from a measured capture.

Fig 4  touch -> stable -> adjustment -> release, three DoG scales
Fig 5  causal DoG vs 16-tap moving-average differential:
       (left) onset zoom, (right) measured frequency response

The DoG kernels come from ttcgs_golden_model, i.e. the same coefficients that
gen_coeffs.py bakes into dog_coeffs.mem and the RTL reads at run time. The
figures therefore show what the hardware computes, not a re-derivation of it.

    python make_paper_figs.py CAPTURE.csv --ch ch0
    python make_paper_figs.py CAPTURE.csv --ch rp --marks 12.4 18.9 24.1 31.0
    python make_paper_figs.py CAPTURE.csv --ch ch0 --start 5 --end 40

--marks overrides the phase boundaries; without it the mark column is used,
and failing that the boundaries are left off rather than guessed.
"""
import argparse, csv, os, sys
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ttcgs_golden_model import dog_pipeline, make_kernels, FS, N_TAPS, SIGMAS

INK, ACC, MUT = "#1a1a1a", "#c0392b", "#7f8c8d"


def load(path, ch):
    t, y, marks = [], [], []
    with open(path, encoding="utf-8") as f:
        for r in csv.DictReader(f):
            v = r.get(ch)
            if v in (None, ""):
                continue
            tt = float(r["t_s"])
            # screen the LDC artefacts documented in DATA/README.md
            if ch in ("rp", "l"):
                if (r.get("chip_id") or "") == "FF" or int(r.get("no_osc") or 0):
                    continue
            t.append(tt); y.append(float(v))
            if r.get("mark"):
                marks.append(tt)
    return np.array(t), np.array(y), marks


def resample_1k(t, y):
    """The pipeline is specified at 1 kSPS; put the capture on that grid."""
    g = np.arange(t[0], t[-1], 1.0 / FS)
    return g, np.interp(g, t, y)


N_MA = 16


def ma_kernel(n_taps=N_TAPS, n=N_MA):
    """The MA differential the paper compares against: y[n] = x[n] - MA_n(x).

    This must stay identical to 05_figures/make_fig6.py, which produced the
    analytical response in the paper. A difference of two adjacent moving
    averages is a different filter — a band-pass with nulls rather than a
    high-pass — and using it here would put the measured figure in direct
    contradiction with the analytical one a few pages earlier.
    """
    k = np.zeros(n_taps)
    k[0] = 1.0            # delta
    k[:n] -= 1.0 / n      # minus boxcar
    return k


def ma_diff(x, n=N_MA):
    return np.convolve(x, ma_kernel(N_TAPS, n), mode="full")[: len(x)]


def fig4(t, feats, marks, ch, out, labels=None):
    fig, axes = plt.subplots(3, 1, figsize=(9, 6.4), sharex=True,
                             gridspec_kw={"hspace": 0.14})
    rows = [("$G_{\\sigma_3}$\n(sustained level)", feats["G_s3"]),
            ("$DoG_{slow}$\n$\\sigma_2-\\sigma_3$, SA-I", feats["DoG_slow"]),
            ("$DoG_{fast}$\n$\\sigma_1-\\sigma_2$, FA-I", feats["DoG_fast"])]
    for ax, (lab, y) in zip(axes, rows):
        ax.plot(t, y, lw=0.8, color=INK)
        ax.axhline(0, lw=0.5, color=MUT, alpha=0.6)
        ax.set_ylabel(lab, fontsize=8.5, linespacing=1.4)
        ax.grid(alpha=0.15, lw=0.5)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
        for i, m in enumerate(marks):
            if not (t[0] <= m <= t[-1]):
                continue
            ax.axvline(m, lw=0.7, color=ACC, ls=":", alpha=0.8)
            # only name a phase if the caller supplied names; guessing them
            # would put a caption on the figure that the capture cannot support
            if ax is axes[0] and labels and i < len(labels):
                ax.annotate(labels[i], xy=(m, ax.get_ylim()[1]),
                            xytext=(3, -10), textcoords="offset points",
                            fontsize=7.5, color=ACC, rotation=90, va="top")
    axes[-1].set_xlabel("time (s)")
    axes[0].set_title(
        f"Measured touch / release, channel {ch} — three causal DoG scales\n"
        f"$\\sigma$ = {', '.join(str(s) for s in SIGMAS)}, {N_TAPS} taps, "
        f"{FS:.0f} SPS; identical kernels to the on-FPGA coefficient ROM",
        fontsize=9.5, loc="left", color=INK)
    fig.savefig(out, bbox_inches="tight", facecolor="white")
    print("wrote", out)


def fig5(t, x, feats, out):
    dog = feats["DoG_fast"]
    ma = ma_diff(x)
    # onset = steepest rise of the wide-kernel baseline
    i0 = int(np.argmax(np.abs(np.diff(feats["G_s3"]))))
    a, b = max(0, i0 - int(0.15 * FS)), min(len(t), i0 + int(0.45 * FS))

    fig, (axL, axR) = plt.subplots(1, 2, figsize=(10, 3.6),
                                   gridspec_kw={"wspace": 0.25})
    for y, lab, c, ls in ((dog[a:b], "causal DoG", INK, "-"),
                          (ma[a:b], "16-tap MA differential", ACC, "--")):
        axL.plot((t[a:b] - t[i0]) * 1e3, y / (np.abs(y).max() or 1),
                 lw=1.1, color=c, ls=ls, label=lab)
    axL.axvline(0, lw=0.5, color=MUT)
    axL.axhline(0, lw=0.5, color=MUT, alpha=0.6)
    axL.set_xlabel("time relative to onset (ms)")
    axL.set_ylabel("normalised response")
    axL.set_title("touch-onset rising edge", fontsize=9.5, loc="left")
    axL.legend(fontsize=8, frameon=False)

    def spec(h):
        """Normalised to 0 dB peak, as in make_fig6.py — the comparison is of
        shape (sidelobes vs monotonic roll-off), not of absolute gain."""
        H = np.abs(np.fft.rfft(h, 8192))
        mag = 20 * np.log10(H + 1e-12)
        return np.fft.rfftfreq(8192, 1 / FS), mag - mag.max()

    k = make_kernels()
    f, Hd = spec(k[0] - k[1])
    _, Hm = spec(ma_kernel())
    axR.plot(f, Hd, lw=1.1, color=INK, label="causal DoG")
    axR.plot(f, Hm, lw=1.1, color=ACC, ls="--", label="16-tap MA differential")
    # The claim is the *gap* between the curves at 300 Hz, so draw the gap
    # rather than pointing at one of its ends.
    i300 = np.argmin(np.abs(f - 300))
    lo, hi = Hd[i300], Hm[i300]
    axR.annotate("", xy=(300, hi), xytext=(300, lo),
                 arrowprops=dict(arrowstyle="<->", color=ACC, lw=1.0))
    axR.plot([300, 300], [lo, hi], lw=0, color=ACC)
    for yv in (lo, hi):
        axR.plot([300 - 12, 300 + 12], [yv, yv], lw=0.7, color=ACC, alpha=0.7)
    axR.annotate(f"{hi-lo:.0f} dB\nat 300 Hz", xy=(300, (lo + hi) / 2),
                 xytext=(14, 0), textcoords="offset points",
                 fontsize=8, color=ACC, va="center", linespacing=1.3)
    axR.set_xlim(0, 500); axR.set_ylim(-70, 3)
    axR.set_xlabel("frequency (Hz)"); axR.set_ylabel("magnitude (dB)")
    axR.set_title("frequency response", fontsize=9.5, loc="left")
    axR.legend(fontsize=8, frameon=False, loc="lower left")

    for ax in (axL, axR):
        ax.grid(alpha=0.15, lw=0.5)
        for s in ("top", "right"):
            ax.spines[s].set_visible(False)
    fig.savefig(out, bbox_inches="tight", facecolor="white")
    print("wrote", out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--ch", default="ch0")
    ap.add_argument("--start", type=float, default=None)
    ap.add_argument("--end", type=float, default=None)
    ap.add_argument("--marks", type=float, nargs="*", default=None)
    ap.add_argument("--labels", nargs="*", default=None,
                    help='phase names for the marks, e.g. --labels "touch onset" '
                         '"stable grasp" "adjustment" release')
    ap.add_argument("--outdir", default=".")
    a = ap.parse_args()

    t, y, marks = load(a.capture, a.ch)
    if len(t) < N_TAPS * 2:
        sys.exit(f"only {len(t)} usable samples on '{a.ch}' — nothing to filter")
    if a.start is not None:
        m = t >= a.start; t, y = t[m], y[m]
    if a.end is not None:
        m = t <= a.end; t, y = t[m], y[m]
    if a.marks:
        marks = a.marks

    native = len(t) / (t[-1] - t[0])
    g, x = resample_1k(t, y)
    feats = dog_pipeline(x)

    # Drop the FIR warm-up. Starting from zero state, the 256-tap kernels ramp
    # from 0 to the signal level over their own length, which dwarfs everything
    # that follows. The hardware does not show this: the z-score engine spends
    # its first 512 samples calibrating at rest, so the pipeline is settled
    # before any feature is emitted.
    w = N_TAPS
    g = g[w:]
    feats = {k: v[w:] for k, v in feats.items()}
    x = x[w:]

    print(f"{a.capture}  ch={a.ch}")
    print(f"  {len(t)} samples at {native:.0f} SPS native -> {len(g)} @ {FS:.0f} SPS"
          f"  ({g[-1]-g[0]:.1f} s after dropping {w} warm-up samples)")
    if native < FS * 0.8:
        print(f"  NOTE: native rate is {native:.0f} SPS, well under the {FS:.0f} SPS the")
        print(f"        pipeline assumes. Upsampling adds no information, so the")
        print(f"        DoG-vs-MA comparison has no out-of-band content to separate")
        print(f"        on and the two will overlap. Use a genuine {FS:.0f} SPS capture")
        print(f"        (an ADS channel) for the figure that goes in the paper.")
    print(f"  marks={len(marks)}")

    stem = os.path.splitext(os.path.basename(a.capture))[0]
    fig4(g, feats, marks, a.ch, os.path.join(a.outdir, f"fig4_{stem}_{a.ch}.svg"),
         labels=a.labels)
    fig5(g, x, feats, os.path.join(a.outdir, f"fig5_{stem}_{a.ch}.svg"))
