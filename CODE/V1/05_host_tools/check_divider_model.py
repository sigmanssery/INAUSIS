# -*- coding: utf-8 -*-
"""Does the plain divider model explain the measured amplitude of each rung?

    python check_divider_model.py <sweep.csv>

The ladder table assumes a constant 0.311 counts per wiper step, and the
recordings do not agree with it -- the measured step size runs from about 0.28
to 0.36 across the rungs.  Two effects can do that and they have to be told
apart before either is quoted:

  1. the divider is nonlinear in R_top, which is arithmetic and predictable;
  2. the ADC's input current flowing through a very high source resistance,
     which is not.  TI's own thermocouple cookbook (SBAA355A) keeps the input
     series resistance low for exactly this reason, and its reference design
     uses kilohm-class resistors where this rig has 1.9 MOhm.

So: fit the bias from the rest point, predict each rung's amplitude from the
divider alone, and look at the residual.  A residual that is small and
unstructured means the divider explains it and the input current is not
significant here.  A residual that grows with amplitude does not.
"""
import sys

import numpy as np

FPS = 689.40
REST = 1746
R_REF = 100000.0          # bottom leg
R_STEP = 390.625          # one AD5254 step, nominal
R_W = 600.0               # series wiper resistance of the eight channels
FULL = 32767.0

AMP_OF = [1, 2, 3, 4, 6, 9, 13, 19, 27, 39, 57, 82, 119, 173, 250, 363, 526,
          763, 1106]


def counts_of(r_top):
    return FULL * R_REF / (R_REF + r_top)


def main(path):
    d = np.genfromtxt(path, delimiter=",", names=True)
    a = d["d13"].astype(np.int64) & 0xFFFF
    rung, code = (a >> 11) & 0x1F, a & 0x7FF
    raw = d["d12"].astype(float)

    off = (code != REST).astype(np.int8)
    e = np.diff(np.concatenate(([0], off, [0])))
    starts, ends = np.where(e == 1)[0], np.where(e == -1)[0]
    base = np.median(raw[off == 0])

    # The bias is whatever makes the rest point come out right; it is a
    # mechanical trimmer, so it is fitted rather than assumed.
    r_top_rest = R_REF * (FULL / base - 1.0)
    bias = r_top_rest - (REST * R_STEP + R_W)
    print("%s" % path)
    print("rest raw %.1f -> R_top %.0f -> fitted bias %.0f ohm" % (base, r_top_rest, bias))
    print()
    print("rung  step   measured   divider-model   residual   counts/step")
    print("-" * 66)

    for r in sorted(set(rung[off == 1].tolist())):
        sel = [(s, ee) for s, ee in zip(starts, ends) if rung[s] == r]
        if not sel or r >= len(AMP_OF):
            continue
        meas = np.mean([abs(np.median(raw[s:ee][len(raw[s:ee]) // 3:]) - base)
                        for s, ee in sel])
        step = AMP_OF[r]
        pred = abs(counts_of(bias + (REST - step) * R_STEP + R_W) - base)
        print("  %2d  %5d   %8.2f   %13.2f   %+8.2f   %8.4f"
              % (r, step, meas, pred, meas - pred, meas / step))

    # The nominal 390.625 ohm step assumes an exactly nominal AD5254, and the
    # part is specified to +/-20% end to end.  Fit the step from the rungs whose
    # amplitude is well above the noise, re-fitting the bias for each candidate
    # so the rest point still lands where it was measured.  If one scale factor
    # flattens the residual, the divider model is fine and the step value is
    # simply not nominal -- which is a calibration number, not a defect.
    fit_rungs = [r for r in sorted(set(rung[off == 1].tolist()))
                 if 11 <= r < len(AMP_OF)]
    meas = {}
    for r in fit_rungs:
        sel = [(s, ee) for s, ee in zip(starts, ends) if rung[s] == r]
        meas[r] = np.mean([abs(np.median(raw[s:ee][len(raw[s:ee]) // 3:]) - base)
                           for s, ee in sel])

    best = None
    for rs in np.arange(340.0, 420.0, 0.05):
        b = r_top_rest - (REST * rs + R_W)
        err = sum((meas[r] - abs(counts_of(b + (REST - AMP_OF[r]) * rs + R_W) - base)) ** 2
                  for r in fit_rungs)
        if best is None or err < best[1]:
            best = (rs, err, b)
    rs, _, b = best
    print()
    print("fitted step %.2f ohm (nominal %.2f, %+.1f%%), bias %.0f ohm"
          % (rs, R_STEP, 100.0 * (rs / R_STEP - 1.0), b))
    print("rung   measured   refitted-model   residual")
    print("-" * 46)
    worst = 0.0
    for r in fit_rungs:
        pred = abs(counts_of(b + (REST - AMP_OF[r]) * rs + R_W) - base)
        worst = max(worst, abs(meas[r] - pred) / max(pred, 1e-9))
        print("  %2d   %8.2f   %14.2f   %+8.2f" % (r, meas[r], pred, meas[r] - pred))
    print()
    if worst < 0.02:
        print("Worst residual %.1f%% -- one scale factor explains it, so the divider"
              % (100 * worst))
        print("model holds and the step above is the number to quote for amplitude.")
    else:
        print("Worst residual %.1f%% -- a single scale factor does NOT explain it."
              % (100 * worst))
        print("Then look at the ADC input current through this 1.9 MOhm source:")
        print("TI's SBAA355A keeps the input series resistance low for that reason,")
        print("and its reference design uses kilohm-class parts, not megohm.")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "2026-09-12_floor_r8fix.csv")
