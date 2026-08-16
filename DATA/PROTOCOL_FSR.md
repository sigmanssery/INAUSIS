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

| Step | Target | Force | Dwell | Type at start of dwell |
|---:|---:|---:|---:|---|
| 1 | 0 g | 0 N | 30 s | `up_0` |
| 2 | 100 g | 0.98 N | 30 s | `up_100` |
| 3 | 200 g | 1.96 N | 30 s | `up_200` |
| 4 | 500 g | 4.90 N | 30 s | `up_500` |
| 5 | 1000 g | 9.81 N | 30 s | `up_1000` |
| 6 | 1500 g | 14.7 N | 30 s | `up_1500` |
| 7 | 2000 g | 19.6 N | 30 s | `up_2000` |
| 8 | 1500 g | | 30 s | `dn_1500` |
| 9 | 1000 g | | 30 s | `dn_1000` |
| 10 | 500 g | | 30 s | `dn_500` |
| 11 | 200 g | | 30 s | `dn_200` |
| 12 | 100 g | | 30 s | `dn_100` |
| 13 | 0 g | | 60 s | `dn_0` |

**Both directions are required.** Hysteresis is the FSR's largest known defect; a
loading-only curve hides it, and a figure that hides it will not survive review.

Total ≈ 7 minutes. At 159 SPS per channel each 30 s dwell holds ≈4770 samples, and
**only the last 10 s of each is used** — the rest is the force settling.

Write the end-of-dwell scale reading on paper as you go:

```
up_0 ____  up_100 ____  up_200 ____  up_500 ____  up_1000 ____  up_1500 ____  up_2000 ____
dn_1500 ____  dn_1000 ____  dn_500 ____  dn_200 ____  dn_100 ____  dn_0 ____   (grams)
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

1. **Check the warm-up rows.** The first ~90 rows of a capture carry
   `chip_id = FF` — the LDC has not joined the bus yet and those rows are
   meaningless. Drop them. This has already been mistaken once for channel
   corruption.
2. **Confirm no bit shift.** No sample should sit near half or double the local
   median. If any do, the bitstream is not `dual_rddelay.fs`.
3. **Check the unloaded baseline is high.** An unloaded FSR402 is well above 1 MΩ,
   i.e. under ~3000 counts. A low unloaded reading means the clamp never fully
   released, or the alumina is still resting on it.
4. **Do not read min/max as the result.** These statistics are set by one or two
   samples and have repeatedly produced wrong conclusions in this project. Use the
   median and the distribution.
