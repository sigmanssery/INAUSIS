# -*- coding: utf-8 -*-
"""False-alarm EVENTS (not frames) at rest, from a digipot_rig sweep capture.

floor_from_sweep reports flagged FRAMES, which overcounts: one false alarm that
the band holds up for 40 frames is one event, not forty.  A run this long needs
the event count and the per-event length before any rate can be quoted.
"""
import sys
import numpy as np
import pandas as pd

FPS, REST = 689.40, 1746
path = sys.argv[1]
cols = ["d13", "d12", "mask"]
df = pd.read_csv(path, usecols=cols, dtype=dict((c, np.int64) for c in cols))
a = df["d13"].to_numpy() & 0xFFFF
code = a & 0x7FF
raw = df["d12"].to_numpy().astype(float)
mask = df["mask"].to_numpy()
del df

off = (code != REST).astype(np.int8)
edge = np.diff(np.concatenate(([0], off, [0])))
ends = np.where(edge == -1)[0]
guard = int(0.7 * FPS)
clear = off.copy()
for e in ends:
    clear[e:min(e + guard, len(clear))] = 1
at_rest = clear == 0

print("%s" % path)
print("rest %d frames = %.1f s (%.2f h)"
      % (at_rest.sum(), at_rest.sum() / FPS, at_rest.sum() / FPS / 3600))
print("rest raw mean %.1f  sd %.2f" % (raw[at_rest].mean(), raw[at_rest].std()))
print()
print("band    frames   events   longest   rate (events/h)")
print("-" * 52)
hours = at_rest.sum() / FPS / 3600
for b, name in ((0, "d0 fast"), (1, "d1 slow"), (2, "d2 G_s3"), (3, "raw3")):
    bit = ((mask >> b) & 1).astype(np.int8) * at_rest
    ed = np.diff(np.concatenate(([0], bit, [0])))
    s, e = np.where(ed == 1)[0], np.where(ed == -1)[0]
    longest = int((e - s).max()) if len(s) else 0
    print("%-8s %6d   %6d   %5d f   %8.2f"
          % (name, int(bit.sum()), len(s), longest, len(s) / hours))
anyb = ((mask != 0).astype(np.int8)) * at_rest
ed = np.diff(np.concatenate(([0], anyb, [0])))
s = np.where(ed == 1)[0]
print("%-8s %6d   %6d              %8.2f"
      % ("any", int(anyb.sum()), len(s), len(s) / hours))
