# The sample rate does not match the specification

An open, unresolved discrepancy, recorded here rather than buried. It affects
figures in both manuscripts, so it should be settled before either is submitted.

## What the papers say

> four single-ended dividers, **1 kSPS each** … The four channels at 1 kSPS each
> fully allocate the converter's 4 kSPS aggregate ceiling

The DoG scales are defined in **samples** — σ₁ = 2, σ₂ = 8, σ₃ = 85 — so every
frequency claim derived from them assumes 1000 SPS: DoG_fast peaking near 48 Hz
against the FA-I band, DoG_slow near 5 Hz against SA-I, and the ~20 ms reflex
settling time.

## What the hardware does

`ads114s08_spi.v` configures `DATARATE = 0x3A`: **MODE 1 (single-shot)**,
FILTER 1, **DR = 800 SPS**, internal clock. The comment in that file already
flags why this matters — *"TTCGS defines its DoG sigmas in SAMPLES … a drifting
rate drags the claimed passbands with it"*.

Measured, from `DATA/` (`2026-07-30_ADS_corner-marked_raw.csv`, 3861 rows at
97 rows/s):

```
consecutive identical samples   ch0 72.1%   ch1 71.2%   ch2 70.9%   ch3 73.8%
median run of identical values  2 rows
=> real update rate            ~48 SPS per channel,  ~192 SPS aggregate
```

Not 800, and not 1000. The driver is single-shot: each channel waits out a full
conversion before the next is started, so the four channels run in series with
SPI overhead between them, and the aggregate lands roughly 20× below the
specified figure.

## What follows

- **The passband claims move.** At 800 SPS the DoG_fast peak is ≈38.7 Hz rather
  than 48 Hz; at 48 SPS the σ₁ = 2 kernel is no longer a 2 ms kernel at all.
- **`FS = 1000` is hardcoded** in `01_golden_model/ttcgs_golden_model.py`, which
  is where the 53.3 / 62.8 dB SNR figures come from, and in
  `make_paper_figs.py`, which resamples a capture onto a 1 kHz grid before
  filtering. Both therefore analyse a rate the hardware does not produce.
- **`top_dual.v`'s `STREAM_MODE = 1` (1 kHz UART) does not fix it.** The UART is
  not the binding constraint at this rate; each value would simply be repeated
  about twenty times.

## Not yet decided

Three ways out, and the choice is a design decision rather than a bug fix:

1. **Make the hardware meet the spec.** Continuous-conversion mode with mux
   switching instead of per-channel single-shot. This is the only route that
   preserves every published number, and it is real RTL work in
   `ads114s08_spi.v`.
2. **Re-derive the numbers at the achieved rate.** Set `FS` to what the hardware
   does, regenerate the coefficients, and update the passband and settling
   claims in the papers. Cheap, honest, and it changes text in both manuscripts.
3. **Decouple them.** Keep σ in samples, state the sample rate as a parameter,
   and give the band centres as a function of it. Most defensible, most editing.

Nothing here is decided. Until it is, do not quote a frequency derived from
`FS = 1000` as a measured property of this hardware.
