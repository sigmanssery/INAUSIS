# Protocol — FSR402 force calibration

A stepped load–unload sweep plus a tap series, on a reference force sensor with a
known active area. Run it once, carefully; it produces three things at the same
time:

1. **A force axis.** Every other pressure measurement in this project currently
   has counts on one axis and nothing on the other.
2. **The DoG waveforms** for the TTCGS figures — real transients from real
   contact, rather than replayed synthetic steps.
3. **The evidence for the sample-rate decision.** 159 SPS per channel either
   resolves a contact onset or it does not. That question has been argued from a
   model; this settles it from data. See [ROADMAP.md](../ROADMAP.md).

The FSR is **not** the sensor of this project. It is a reference with a
manufacturer-specified area and range, used to calibrate the chain and to produce
figures that do not depend on the elastomer being finished.

---

## Sensor

| | |
|---|---|
| Part | Interlink FSR402 |
| Active area | 12.7 mm diameter = **1.267 cm²** |
| Force range | **0–20 N** (≈ 0–2040 g) |
| At full scale | 19.6 N / 1.267 cm² = **155 kPa** |

FSR402 is a force-sensing *resistor*, not a load cell: it is repeatable to roughly
±10% part-to-part and shows real hysteresis. That is acceptable here because the
scale — not the FSR — supplies the force axis. The FSR supplies the resistance.

---

## Wiring

> **The tail is printed silver on Mylar and cannot be soldered.** Heat lifts the
> ink off the substrate and destroys the part. Use a 0.1″ female header to grip
> the tail, and solder the wires from the header to the board pads.

The board-pad end **must be soldered**. Pressure contact on those pads has been
measured at tens of megohms through what is most likely a silicone or
surface-finish film — a known 100 kΩ read 30 counts (≈55 MΩ implied) under four
different clamping arrangements, and read correctly the moment it was soldered.
See [README.md](README.md).

```
FSR tail ── 0.1" female header ── wires ── soldered to ch0 pads (AIN5, corner B)
```

Remove any calibration resistor still fitted before connecting the FSR.

### The divider must be resized for this sensor

The board's 100 kΩ divider is chosen for the elastomer, which sits in the megohm
range. An FSR402 works between about 1 kΩ and 100 kΩ, and at the loaded end the
100 kΩ divider barely moves.

| | R_div = 100 kΩ | R_div = 10 kΩ |
|---|---:|---:|
| sensitivity at R = 3 kΩ | 309 counts/kΩ | **1939 counts/kΩ** |
| sensitivity at R = 1.3 kΩ | 319 counts/kΩ | **2566 counts/kΩ** |

**Fit ~11 kΩ from the ch0 AIN pad to GND**, in parallel with the divider already
there: 11 ∥ 100 = 9.91 kΩ. Nothing has to be removed.

**Also remove any series resistor in the FSR leg.** The first run carried 43 kΩ in
series, so a 1.3 kΩ sensor was read as 44.3 kΩ and contributed 3% of the total —
the divider was measuring the fixed resistor, not the sensor.

Re-verify after changing it, with the two-point method in [README.md](README.md):
a known 10 kΩ should read ≈16 400 counts.

**Bitstream:** `dual_rddelay.fs` — the one carrying the `RD_DELAY` fix. Captures
taken with anything earlier carry a one-bit shift on a few percent of samples.

---

## Mechanical setup

The C-clamp grips the whole stack, scale included, so the scale reads the clamp
force directly:

```
   ┌─ clamp jaw ─┐
   │   alumina   │   25 × 20 × 30 mm, 99% Al2O3
   │  ▓▓ FSR ▓▓  │   active area centred under the block
   │   alumina   │
   │  ── scale ──│   platform loaded against its own base
   └─ clamp jaw ─┘
```

Centre the alumina over the 12.7 mm active area. An off-centre block loads part of
the area and the pressure figure stops meaning anything.

> **A screw clamp is displacement control, not force control.** Once tightened it
> holds *position*, so as the FSR creeps the force **decays** over the dwell — the
> scale reading will fall on its own. This is not a fault and it is not drift in
> the sensor.
>
> The consequence for the protocol: **read the scale at the end of the dwell, in
> the same window as the ADC samples.** Pairing a start-of-dwell force with an
> end-of-dwell resistance is the easiest way to manufacture a fake hysteresis
> loop.

---

## Sweep protocol

One capture for the whole sweep. `log_dual.py` stamps a label into the `mark`
column when you type it and press ENTER, so the steps are recoverable from a
single file — do not split into one file per step.

> **Put the steps below 1 kg.** The first run of this protocol used steps from
> 400 g to 2329 g and **14 of its 18 points landed in the flat region**, where the
> FSR is bottomed out at 1–2 kΩ and returns no information. The part's own curve
> is steep below ~500 g and flat above ~1 kg; the interesting decade is the one
> under 5 N. Measured on 2026-08-16:
>
> | force | R_FSR |
> |---:|---:|
> | 3.92 N | 16.0 kΩ |
> | 6.18 N | 4.8 kΩ |
> | 8.00 N | 2.7 kΩ |
> | 9.42 N | 1.3 kΩ |
> | 9.4 → 22.8 N | 1.1–1.6 kΩ, no trend |

| Step | Target | Force | Dwell | Type at start of dwell |
|---:|---:|---:|---:|---|
| 1 | 0 g | 0 N | 30 s | `up_0` |
| 2 | 20 g | 0.20 N | 30 s | `up_20` |
| 3 | 50 g | 0.49 N | 30 s | `up_50` |
| 4 | 100 g | 0.98 N | 30 s | `up_100` |
| 5 | 150 g | 1.47 N | 30 s | `up_150` |
| 6 | 200 g | 1.96 N | 30 s | `up_200` |
| 7 | 300 g | 2.94 N | 30 s | `up_300` |
| 8 | 400 g | 3.92 N | 30 s | `up_400` |
| 9 | 600 g | 5.89 N | 30 s | `up_600` |
| 10 | 800 g | 7.85 N | 30 s | `up_800` |
| 11 | 1000 g | 9.81 N | 30 s | `up_1000` |
| 12 | 800 g | | 30 s | `dn_800` |
| 13 | 600 g | | 30 s | `dn_600` |
| 14 | 400 g | | 30 s | `dn_400` |
| 15 | 200 g | | 30 s | `dn_200` |
| 16 | 100 g | | 30 s | `dn_100` |
| 17 | 50 g | | 30 s | `dn_50` |
| 18 | 0 g | | 60 s | `dn_0` |

**`up_0` means the clamp is off, not slack.** In the first run the "unloaded"
baseline already read 10.8 kΩ and the final 0 g point read 4.3 kΩ — the stack was
never actually released, so the curve has no zero.

**Both directions are required.** Hysteresis is the FSR's largest known defect; a
loading-only curve hides it, and a figure that hides it will not survive review.

Total ≈ 7 minutes. At 159 SPS per channel each 30 s dwell holds ≈4770 samples, and
**only the last 10 s of each is used** — the rest is the force settling.

Write the end-of-dwell scale reading on paper as you go:

```
up_0 ___  up_20 ___  up_50 ___  up_100 ___  up_150 ___  up_200 ___
up_300 ___  up_400 ___  up_600 ___  up_800 ___  up_1000 ___
dn_800 ___  dn_600 ___  dn_400 ___  dn_200 ___  dn_100 ___  dn_50 ___  dn_0 ___
                                                                        (grams)
```

`dn_0` gets 60 s because recovery is the slow direction — the FSR has been seen
climbing 30 k → 120 kΩ over minutes after unloading.

---

## Tap series

Separate capture, no clamp. Finger taps directly on the FSR:

```
5 × sharp taps, roughly 1 s apart      mark: tap
5 × press-and-hold ~2 s, then release  mark: hold
```

This is the capture that answers the sample-rate question. What matters is whether
the **onset edge** is resolved — how many samples span the rise from baseline to
plateau. At 159 SPS one sample is 6.3 ms. If an onset occupies 2–3 samples, the
edge is marginally resolved and the DoG scales need re-deriving for the real rate;
if it occupies 10+, 159 SPS is sufficient and the manuscripts' passbands can be
restated in seconds rather than samples.

---

## Naming

```
data/2026-08-16_FSR402_sweep_raw.csv
data/2026-08-16_FSR402_taps_raw.csv
```

---

## Analysis

Convert counts with the calibrated ratiometric form from [README.md](README.md):

```
R_fsr = 100 kΩ × (32767 / counts − 1)
```

Then per step, over the **last 10 s** of each dwell:

| Quantity | From |
|---|---|
| Force | scale reading at end of dwell, × 9.81 mN/g |
| Pressure | force / 1.267 cm² |
| Conductance | 1 / R_fsr — FSR conductance is closer to linear in force than resistance is |
| Spread | sd over the window, to put error bars on the curve |

Plot **conductance against force**, both directions on the same axes, up and down
distinguished. Resistance-against-force is the conventional plot and it is the
less informative one: it compresses the entire high-force half of the range into
the bottom of the axis.

---

## Before trusting the result

1. **`chip_id = FF` for the whole file is expected here.** The LDC is simply not
   connected during ADS-only work. [README.md](README.md)'s screening rule reads
   `FF` as a dropped SPI link and says to discard the row — that rule is for
   dual-modal captures and would throw away every row of an FSR run. It applies to
   the LDC fields, not to `ch0`–`ch3`. A *scattered* `FF` in a dual-modal capture
   still means what the rule says it means.

2. **Raise the rail threshold.** `log_dual.py` defaults to `--rail 20000`, but a
   loaded FSR legitimately reads above that, so `bad_ads` fired on 97% of the
   first run and meant nothing. Use `--rail 32000` for FSR work.
3. **Confirm no bit shift.** No sample should sit near half or double the local
   median. If any do, the bitstream is not `dual_rddelay.fs`.
4. **Check the unloaded baseline is high.** An unloaded FSR402 is well above 1 MΩ,
   i.e. under ~3000 counts. A low unloaded reading means the clamp never fully
   released, or the alumina is still resting on it.
5. **Do not read min/max as the result.** These statistics are set by one or two
   samples and have repeatedly produced wrong conclusions in this project. Use the
   median and the distribution.
