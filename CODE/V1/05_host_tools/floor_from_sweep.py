# -*- coding: utf-8 -*-
"""Detection floor from a digipot_rig sweep recording.

    python floor_from_sweep.py <sweep.csv>

The rig walks an amplitude ladder and labels every frame in dim13 with
{rung[4:0], code[10:0]}, so the stimulus does not have to be inferred from the
signal -- each presentation is bracketed by the frames whose rung is that rung
and whose code has left the rest value.  That labelling is the whole point:
the 2026-08-30 floor had to be read off a generator whose own step was the
limit being measured.

For each rung this reports how many presentations were detected by each band,
and the amplitude in ADC counts derived FROM THE RECORDING rather than from the
ladder table -- the table assumes a 1.25 MOhm bias and an exactly nominal
digipot, and the part is specified to +/-20% end to end.
"""
import sys

import numpy as np

FPS = 689.40
REST = 1746            # DIGIPOT_CODE; a presentation is any frame off this


def main(path):
    d = np.genfromtxt(path, delimiter=",", names=True)
    a = d["d13"].astype(np.int64) & 0xFFFF
    rung = (a >> 11) & 0x1F
    code = a & 0x7FF
    raw = d["d12"].astype(float)
    mask = d["mask"].astype(np.int64)

    # A presentation is a maximal run where the code has left the rest value.
    off = (code != REST).astype(np.int8)
    edge = np.diff(np.concatenate(([0], off, [0])))
    starts, ends = np.where(edge == 1)[0], np.where(edge == -1)[0]
    print("%s" % path)
    print("%d frames, %.1f s, %d presentations" % (len(a), len(a) / FPS, len(starts)))
    if not len(starts):
        sys.exit("no presentations -- is DIGIPOT_MAN still 1?")

    # rest level from the frames between presentations, which is also the only
    # honest place to take it from: a level taken inside a presentation would
    # include the stimulus it is supposed to be measured against.
    base = np.median(raw[off == 0])
    print("rest raw %.1f counts, rest sd %.2f" % (base, raw[off == 0].std()))
    print()
    print("rung  step   n   amplitude(counts)    detected: d0    d1    d2   raw3   any")
    print("-" * 82)

    for r in sorted(set(rung[off == 1].tolist())):
        sel = [(s, e) for s, e in zip(starts, ends) if rung[s] == r]
        if not sel:
            continue
        amps, hits = [], np.zeros(5, dtype=int)
        step = 0
        for s, e in sel:
            step = int(abs(int(code[s:e].min()) - REST))
            # amplitude measured, not assumed: the extreme of the held part
            amps.append(abs(np.median(raw[s:e][len(raw[s:e]) // 3:]) - base))
            # The detection window has to run PAST the presentation.  G_sigma3
            # is a 256-tap average -- a 371 ms window -- so its response to a
            # 260 ms presentation lands mostly after the code has returned to
            # rest, and a window that stops at `e` scores it as a miss.  The
            # inter-presentation gap is 690 frames (1.0 s), so 500 ms of run-on
            # cannot reach the next one.
            m = mask[s:min(e + int(0.5 * FPS), len(mask))]
            # dim3 carries the raw channel through the same adaptive
            # threshold (the v34 contact output), so it is a fourth detector and
            # not counting it made `any` disagree with the per-band columns.
            for b in range(4):
                if ((m >> b) & 1).any():
                    hits[b] += 1
            if (m != 0).any():
                hits[4] += 1
        n = len(sel)
        print("  %2d  %5d  %3d   %6.2f +/- %4.2f      %3d/%-3d %3d/%-3d %3d/%-3d %3d/%-3d %3d/%-3d"
              % (r, step, n, np.mean(amps), np.std(amps),
                 hits[0], n, hits[1], n, hits[2], n, hits[3], n, hits[4], n))

    # False positives: only frames at rest AND clear of the previous release.
    #
    # "code == REST" alone is not a negative.  The release is an edge of the
    # same amplitude as the onset, and the bands answer it -- correctly.  With
    # a fast ramp those answers land after the code is already back at rest, so
    # scoring them as false alarms turned a clean run into 1326 phantom ones
    # (and inflated the rest sd from 7 to 43).  The guard has to outlast the
    # slowest band: G_sigma3 is 256 taps = 371 ms, so 700 ms is used, which the
    # 690-frame (1.0 s) gap still leaves room inside.
    guard = int(0.7 * FPS)
    clear = off.copy()
    for e in ends:
        clear[e:min(e + guard, len(clear))] = 1
    q = mask[clear == 0]
    print("rest sd (guarded) %.2f counts over %.1f s"
          % (raw[clear == 0].std(), (clear == 0).sum() / FPS))
    print()
    print("at rest (%d frames, %.1f s): any %d  d0 %d  d1 %d  d2 %d  raw3 %d"
          % (len(q), len(q) / FPS, int((q != 0).sum()), int((q & 1).sum()),
             int(((q >> 1) & 1).sum()), int(((q >> 2) & 1).sum()),
             int(((q >> 3) & 1).sum())))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "2026-09-12_floor_sweep.csv")
