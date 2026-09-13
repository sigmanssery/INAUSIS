# -*- coding: utf-8 -*-
"""Which AD5254 bus is actually being written -- in ten seconds, no rebuild.

    python rig_bus_check.py --port COM7 [--secs 10]
    python rig_bus_check.py <capture.csv>

A channel that has never acknowledged a write sits at the part's EEMEM midscale
(128) instead of its target, and the rest level of the divider moves by a known
number of steps.  At REST_CODE 1746 the targets are bus A {255,255,255,255} and
bus B {255,255,216,0}; midscale is 4 x 128 = 512 per chip, so a dead bus A leaves
the chain 508 steps short and a dead bus B leaves it 214 short.  With the fitted
step of 383.10 ohm and the divider R = 100k (32767/counts - 1), each state has
its own rest level, anchored on 2026-09-12 when both buses were written (1572.0).

The LED cannot make this distinction: led_err ORs both buses' ack_err, and the
walker's shared dev_sel lets a dead bus B starve bus A's addressing as well.

Valid only when the rig has been power-cycled since a bus last worked -- a bus
that breaks while powered keeps its last written values, not midscale.
"""
import subprocess
import sys

import numpy as np
import pandas as pd

REST = 1746
STEP_OHM = 383.10
ANCHOR = 1572.0                  # both buses written, 2026-09-12
DEFICIT = (("A and B written", 0), ("only A written (bus B dead)", 214),
           ("only B written (bus A dead)", 508), ("neither written", 722))


def r_of(c):
    return 100e3 * (32767.0 / c - 1.0)


def c_of(r):
    return 32767.0 * 100e3 / (100e3 + r)


def verdict(path):
    d = pd.read_csv(path, usecols=["d4", "d12", "d13"])
    a = d["d13"].to_numpy() & 0xFFFF
    rest = (a & 0x7FF) == REST
    if rest.sum() < 500:
        sys.exit("only %d rest frames -- is the sweep running?" % rest.sum())
    lvl = float(np.median(d["d12"].to_numpy()[rest]))
    sd = float(d["d12"].to_numpy()[rest].std())
    print("BUILD 0x%04X   rest frames %d   rest raw %.1f (sd %.2f)"
          % (int(d["d4"].iloc[0]) & 0xFFFF, rest.sum(), lvl, sd))
    r0 = r_of(ANCHOR)
    best = None
    for name, steps in DEFICIT:
        pred = c_of(r0 - steps * STEP_OHM)
        dist = abs(lvl - pred)
        print("   %-30s predicted %7.1f   off by %6.1f" % (name, pred, dist))
        if best is None or dist < best[1]:
            best = (name, dist)
    print("-> %s" % best[0])
    return best[0]


if __name__ == "__main__":
    args = sys.argv[1:]
    if "--port" in args:
        port = args[args.index("--port") + 1]
        secs = args[args.index("--secs") + 1] if "--secs" in args else "10"
        out = "rig_bus_check_last.csv"
        subprocess.run([sys.executable, "log_frames.py", "--port", port,
                        "--secs", secs, "--out", out],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        verdict(out)
    else:
        for p in args:
            print("=" * 72)
            print(p)
            verdict(p)
