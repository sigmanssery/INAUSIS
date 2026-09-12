# -*- coding: utf-8 -*-
"""Break a rest capture into mains lines and everything else.

    python mains_anatomy.py <capture.csv> [more.csv ...] [--dim d12]

The question this answers is which kind of noise you are looking at, because
the fix is different for each:

  * a LINE at exactly 60 Hz, with harmonics well below it, is mains coupling --
    capacitive into a high-impedance node.  It scales with node impedance, so
    shielding, shortening the high-Z run, or scaling the divider down helps,
    and re-dressing or twisting the jumpers does not (at 60 Hz the loop-area
    term needs a field about a thousand times larger than a room has).
  * a BROADBAND floor is not mains at all.  If it sits at the quantisation
    step there is nothing left to win; if it sits above it, the source is
    local -- bus activity, a switching wiper, a bad return.

With no arguments it falls back to the two P1 rest recordings so the numbers
quoted in the paper can be re-checked.
"""
import glob
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT = [os.path.join(HERE, "2026-09-10_P1_rest300s_raw.csv"),
           os.path.join(HERE, "2026-09-11_P1_rest300s_away_raw.csv")]
FPS = 689.40
LINES = (60.0, 120.0, 180.0, 240.0)


def amp_at(x, w, f0, fps, half=0.25):
    """RMS amplitude in a narrow band about f0, by Parseval on a Hann window.

    Normalised so a pure sinusoid of rms A comes back as A: the window costs
    sum(w^2)/m of power and the one-sided spectrum doubles every bin but DC.
    A closure check against the total sd is printed, because getting this
    normalisation wrong is silent and was wrong here once already.
    """
    m = len(x)
    X = np.fft.rfft((x - x.mean()) * w)
    f = np.fft.rfftfreq(m, 1.0 / fps)
    k = (f >= f0 - half) & (f <= f0 + half)
    p = (np.abs(X[k]) ** 2).sum() * 2.0 / (m * (w ** 2).sum())
    return np.sqrt(max(p, 0.0))


def report(path, dim):
    d = np.genfromtxt(path, delimiter=",", names=True)
    if dim not in (d.dtype.names or ()):
        print("  %s has no column %s (has: %s)"
              % (os.path.basename(path), dim, ", ".join(d.dtype.names[:8])))
        return
    x = d[dim].astype(float)[500:]                 # drop the warm-up
    m = len(x) // 2 * 2
    x = x[:m]

    # A degenerate capture has to be caught before anything is derived from it:
    # with zero variance every share is 0/0 = nan, and nan fails every
    # comparison, so a naive verdict chain calls a dead channel "clean".
    if m < 4096 or len(np.unique(x)) < 3 or x.std() == 0:
        print("  DEGENERATE: %d samples, %d distinct values, sd %.3f"
              % (m, len(np.unique(x)), x.std() if m else 0.0))
        return

    w = np.hanning(m)
    tot = x.std()
    amp = {f0: amp_at(x, w, f0, FPS) for f0 in LINES}
    mains = sum(v ** 2 for v in amp.values())
    rest = np.sqrt(max(tot ** 2 - mains, 0.0))

    print("  %d samples, %.1f s, %d distinct values" % (m, m / FPS, len(np.unique(x))))
    print("  total sd              %8.3f counts" % tot)
    for f0 in LINES:
        print("    %5.0f Hz            %8.3f counts   (%4.1f%% of power)"
              % (f0, amp[f0], 100.0 * amp[f0] ** 2 / tot ** 2))
    print("  everything else       %8.3f counts" % rest)

    gap = np.diff(np.sort(np.unique(x)))
    step = int(gap.min()) if len(gap) else 0
    share = 100.0 * mains / tot ** 2
    print()
    # "Line-dominated" is not one diagnosis but two, and they have opposite
    # fixes.  Capacitive pickup reproduces the MAINS VOLTAGE, whose THD is a
    # few per cent, so the fundamental dominates.  A full-wave rectified load
    # (SMPS, LED lamp, charger) puts its energy in the EVEN harmonics and
    # leaves the odd ones small -- and no amount of shielding the sensor node
    # helps, because the emitter is somewhere else in the room.
    even = amp[120.0] ** 2 + amp[240.0] ** 2
    odd = amp[180.0] ** 2
    if share > 60.0 and even > amp[60.0] ** 2:
        print("  VERDICT: a RECTIFIED source dominates (%.0f%% in the lines, and"
              % share)
        print("           2f+4f = %.2f counts against f = %.2f, with 3f only %.2f)."
              % (np.sqrt(even), amp[60.0], np.sqrt(odd)))
        print("           Strong even harmonics and weak odd ones is full-wave")
        print("           rectification: an SMPS, an LED lamp, a charger. This is")
        print("           NOT the mains voltage coupling into the node, so")
        print("           shielding and resistor values will not move it.")
        print("           Find the emitter: switch the room lights off and")
        print("           re-record, then unplug chargers one at a time.")
    elif share > 60.0:
        print("  VERDICT: MAINS VOLTAGE dominates (%.0f%% in the lines, the"
              % share)
        print("           fundamental %.2f above 2f+4f = %.2f)."
              % (amp[60.0], np.sqrt(even)))
        print("           This is capacitive pickup into a high-impedance node.")
        print("           It scales with node impedance -- shield or shorten the")
        print("           high-Z run, or scale the divider down. Twisting or")
        print("           re-dressing the jumpers will not move it.")
    else:
        print("  VERDICT: broadband, not mains (%.0f%% in the lines)." % share)
        print("           Look local: bus activity, a switching wiper, the")
        print("           return path. Changing resistor values will not help.")
    print("  With every line removed the capture would sit at %.2f counts." % rest)
    if rest <= 1.5 * step:
        print("  The broadband part (%.2f) is at the quantisation step (%d count)."
              % (rest, step))
        print("  There is nothing left to win underneath it.")
    else:
        print("  The broadband part (%.2f) is %.1fx the quantisation step (%d)"
              % (rest, rest / max(step, 1), step))
        print("  -> there IS room under it; this floor is not converter-limited.")


def main():
    global FPS
    argv = sys.argv[1:]
    dim = "d12"
    if "--dim" in argv:
        i = argv.index("--dim")
        dim = argv[i + 1]
        del argv[i:i + 2]
    # A rig clocked at a different frame rate would put the 60 Hz line in the
    # wrong bin and silently report "broadband", so make the rate explicit
    # rather than assuming the P1 board's.
    if "--fps" in argv:
        i = argv.index("--fps")
        FPS = float(argv[i + 1])
        del argv[i:i + 2]
    args = [a for a in argv if not a.startswith("--")]
    print("frame rate assumed: %.2f fps (override with --fps)\n" % FPS)
    paths = []
    for a in (args or DEFAULT):
        hits = glob.glob(a)
        if not hits:
            print("no such file: %s" % a)
        paths += sorted(hits)
    for p in paths:
        print("=" * 70)
        print("%s   [%s]" % (os.path.basename(p), dim))
        print("=" * 70)
        report(p, dim)
        print()


if __name__ == "__main__":
    main()
