# -*- coding: utf-8 -*-
"""What threshold is the raw contact detector actually using?

    python raw3_threshold.py <sweep.csv> [more.csv ...]

dim3 carries the raw sample the mask judged (`dog_store[3] <= raw_lat`), and
mask bit 3 says when that detector fired, so the threshold does not have to be
inferred from the RTL: it is the smallest deviation from rest at which bit 3 is
set.  Reading it out of the recording also catches the case the RTL cannot
show, which is the rolling mean absorbing part of a slow stimulus.

Why this matters: raw3 is the control the DoG bands are compared against.  It
fired at 397 / 165 / 402 counts in three runs, which is not monotonic in onset
speed and does not match 5 sigma of its own noise (about 50 counts), so the
comparison cannot be quoted until the threshold is understood.
"""
import os
import sys

import numpy as np

FPS = 689.40
REST = 1746


def run(path):
    d = np.genfromtxt(path, delimiter=",", names=True)
    a = d["d13"].astype(np.int64) & 0xFFFF
    code = a & 0x7FF
    rung = (a >> 11) & 0x1F
    d3 = d["d3"].astype(float)
    mk = d["mask"].astype(np.int64)
    fired = ((mk >> 3) & 1).astype(bool)

    off = (code != REST)
    base = np.median(d3[~off])
    sd = d3[~off].std()

    print("=" * 72)
    print(os.path.basename(path))
    print("  dim3 rest level %.1f, rest sd %.2f  -> 5 sigma would be %.1f counts"
          % (base, sd, 5 * sd))

    if not fired.any():
        print("  bit3 never fired in this recording")
        return
    dev = np.abs(d3 - base)
    print("  smallest deviation at which bit3 was set: %.1f counts (%.1f sigma)"
          % (dev[fired].min(), dev[fired].min() / max(sd, 1e-9)))
    print("  largest deviation reached WITHOUT bit3:   %.1f counts (%.1f sigma)"
          % (dev[~fired & off].max(), dev[~fired & off].max() / max(sd, 1e-9)))

    # Per rung: did the held level exceed the apparent threshold, and did it fire?
    print("  rung  held dev   fired")
    for r in sorted(set(rung[off].tolist())):
        m = off & (rung == r)
        if m.sum() < 50:
            continue
        held = np.percentile(dev[m], 75)
        print("    %2d   %8.1f   %s" % (r, held, "yes" if fired[m].any() else "no"))


if __name__ == "__main__":
    for p in (sys.argv[1:] or ["2026-09-12_floor_r8fix.csv"]):
        run(p)
