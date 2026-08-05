# DATA — measured captures and figures

Waveforms and figures from the bring-up and characterization work. Everything here
is measured on the X004 prototype board unless a file says otherwise; nothing is
simulated except `ttcgs_golden.png`, which is the reference the RTL is checked
against.

## Figures

| File | Shows |
|---|---|
| `ttcgs_golden.png` | golden-model reference output — the bit-exact fixed-point model the RTL regression compares against |
| `ttcgs_ADS_A.png` | piezoresistive channel, corner A, via the ADS114S08 divider |
| `ttcgs_tap_C.png` | tap transient on corner C — fast-adapting character |
| `ttcgs_MRE_rp.png` | LDC1101 RP channel responding to MRE compression |
| `ttcgs_poke_L.png` | LDC1101 L channel under a localized poke |

> **To be completed by the author.** Each figure needs its capture conditions
> recorded: date, bitstream, LDC register settings (`RP_SET`, `DIG_CONF`, CLKIN
> divider), loading method and contact area, and — for the inductive traces —
> whether the indenter was conductive. Without those, a trace cannot be compared
> against another session's, because the LDC baselines shift with register
> settings and with coil–skin geometry. The RP baseline in particular moves by
> nearly 2× between `RP_SET` 0x46 and 0x47 for identical physical conditions.

## Capture conventions

Raw captures follow `YYYY-MM-DD_<topic>_raw.csv`, one row per synchronized sample
set, written by `log_dual.py`:

```
t_s, ch0..ch3, rp, l, rp_hex, l_hex, bad_ads, status, no_osc, chip_id, mark
```

| Column | Meaning |
|---|---|
| `ch0`–`ch3` | ADS114S08 channels, 16-bit signed |
| `rp`, `l` | LDC1101 equivalent parallel resistance and inductance, raw counts |
| `bad_ads` | a channel hit the rail this sample |
| `status` | LDC `STATUS` (0x20), sticky since the previous status line |
| `no_osc` | `NO_SENSOR_OSC` bit was set |
| `chip_id` | LDC `CHIP_ID` (0x3F), **re-read every sample loop** |
| `mark` | operator event label, typed during capture |

## Screening a capture before you analyse it

Three checks, in this order. Skipping them has repeatedly produced conclusions that
later turned out to be instrumentation artifacts.

1. **`chip_id` must be `D4`.** `FF` means the MISO line was floating — the LDC was
   off the SPI bus, and every other field in that row is meaningless. Note that
   `FF` also sets the `NO_SENSOR_OSC` bit, so a dead link masquerades as a stalled
   tank; `chip_id` is the only thing that tells them apart. A `00` is benign
   (a read that returned nothing) and does not invalidate the row.

2. **`no_osc` with a *valid* status** is a genuine tank stall. Exclude those rows;
   they are typically well under 1% and are flagged precisely so they can be
   dropped.

3. **Sanity-bound `l` and `rp`.** A healthy idle baseline has `l` standard
   deviation below ~1 count. If it is much larger, something is wrong upstream —
   check the link before interpreting the physics.

## Reference baseline

`2026-08-01`, LDC-only, sensor board on an isolated supply, one hour, 329128 samples:

```
valid samples   100.000%        CHIP_ID 0xFF: 0        tank stalls: 0
L  sd 0.647 counts (best 5-minute window 0.202)
RP sd 619 counts
drift   RP +122 counts/h (+0.39%/h)      L −0.37 counts/h (−0.027%/h)
```

Use this as the no-target reference when normalising other captures. The drift
figures matter for any measurement held longer than a few seconds: over a
three-minute hold the instrument moves about 6 counts, against roughly 5300 counts
for a firm press — a margin of ~900×, which is what makes sustained-load
measurements meaningful at all.
