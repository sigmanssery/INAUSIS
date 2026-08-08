# The sample rate does not match the specification

An open discrepancy, recorded here rather than buried. It affects figures in both
manuscripts, so it should be settled before either is submitted.

The converter's behaviour was measured directly on 2026-08-07 with a logic
analyser. That capture replaced two earlier conclusions on this page, both of
which had been inferred from the UART stream rather than observed on the bus.
The superseded text is kept at the bottom so the correction is auditable.

## What the papers say

> four single-ended dividers, **1 kSPS each** … The four channels at 1 kSPS each
> fully allocate the converter's 4 kSPS aggregate ceiling

The DoG scales are defined in **samples** — σ₁ = 2, σ₂ = 8, σ₃ = 85 — so every
frequency claim derived from them assumes 1000 SPS: DoG_fast peaking near 48 Hz
against the FA-I band, DoG_slow near 5 Hz against SA-I, and the ~20 ms reflex
settling time.

## What the hardware does — measured

`ads114s08_spi.v` configures `DATARATE = 0x3A`: **MODE 1 (single-shot)**,
FILTER 1, **DR = 800 SPS**, internal clock.

Capture `ads_drdy2.sr`: 2.500 s at 4 MHz, five signals mirrored from the ADS SPI
bus onto spare FPGA pins (51/53/57/68/69) so the logic analyser did not have to
contest the header holes with the sensor harness. Build: `TIME_MUX = 0`,
`STREAM_MODE = 0`.

```
DRDY falling edges          1591 over 2.500 s
interval                    1572.2 us   sd 0.4 us   (min 1571.2, max 1573.2)
intervals > 2x median       0
first edge 0.025 ms         last edge 2499.882 ms   (capture is 2500.0 ms)

=> 636.04 Hz aggregate      159.01 SPS per channel
```

Not 800 aggregate, and not 1000 per channel. But the cadence is metronomic — the
whole spread across 1590 intervals is 2 µs.

### Where the 322 µs goes

| | | |
|---|---:|---|
| conversion, `1/DR` | 1250 µs | DR = 800 setting |
| ADC single-shot start-up | 219 µs | inferred from the remainder |
| SPI traffic, 50 clocks | 104 µs | measured CS-low: 34.25 + 68.25 µs |
| **cycle** | **1573 µs** | vs 1572.2 µs measured |

SCLK is **482 kHz**: the SCLK period is `CLK_DIV` system clocks, since the counter
wraps at `CLK_DIV` and the falling strobe fires at `CLK_DIV/2`. The comments in
`ads114s08_spi.v` divided by `2·CLK_DIV` and so claimed 241 kHz — wrong by 2×,
corrected 2026-08-07 in all eight copies of that file. 50 clocks per conversion is
WREG INPMUX (25) + START (8) + data read (17).

### The bus does exactly what the RTL says

Per conversion, decoded off the wire:

```
WREG INPMUX = 5C / 4C / 1C / 0C     25 clocks   S_MUX_I
START 0x08                           8 clocks   S_START_I
(wait DRDY falling)                 1469 us
direct 16-bit read, no RDATA        17 clocks   S_RDATA_I
```

All four `mux_table` codes are visited in order. There is no stray command, no
dropped channel, and no bus error. The driver is correct; it is simply paying
single-shot overhead on every conversion.

> A decode that does not account for `total_bits <= 6'd25` — the 25th clock on a
> 24-bit WREG — shifts the following byte right by one and turns `0x08` (START)
> into `0x04` (POWERDOWN). That is a decoder artifact, not a hardware fault.

## The inputs are flat

Of the 1591 reads, 517 landed in cleanly-framed CS windows and were decoded:

```
+2   501 reads
+1    16 reads
mean +1.97   sd 0.17   range +1..+2
```

A 16-bit converter returning +2 is reading essentially zero. **Whether anything
was connected to the analog inputs during this capture is not recorded** — that
needs confirming before the number is read as a fault. But it is the observation
that dissolves both of the corrections below.

## Two earlier conclusions, withdrawn

**1. "~48 SPS per channel" was measuring the signal, not the rate.**

The old figure came from counting repeated values in
`2026-07-30_ADS_corner-marked_raw.csv` — 72% of consecutive samples identical,
therefore the update rate must be well below the print rate. That inference is
only valid if the signal moves. It does not: the converter returns a constant +2.
The repeat fraction measures a flat input, and says nothing about sample rate.

**2. "TIME_MUX is load-bearing" does not survive either.**

The old text reported that with `TIME_MUX = 0`, ch0 converted once and stopped
and ch1..ch3 never updated, concluding that the periodic 150 ms reset was the
only thing keeping the driver alive. This capture *is* `TIME_MUX = 0`, and the
converter ran 1591 conversions across all four channels with zero stalls and
0.4 µs of jitter.

Four channels all sitting at a constant +2 produce a UART stream that prints the
same four numbers forever — indistinguishable, from the stream alone, from a
stalled converter. That is the more economical explanation, and it needs no
stall mechanism at all.

**Confirmed 2026-08-08.** A read-only 5 s check on the same `TIME_MUX = 0`
bitstream, nothing attached to the analog inputs:

```
CH0  n=553  range 1..3        CH1  n=553  range 0..2
CH2  n=553  range 0..2        CH3  n=553  range 1..2
```

All four channels update, at the same +1..+2 resting value the logic analyser
saw on the bus and the 2026-07-30 capture saw at rest. There is no stall and no
broken latch: the ADS path is healthy end to end — converter, latch, and UART.
`TIME_MUX = 1` is not load-bearing, and the 2026-08-06 all-zero columns came from
something specific to that session's bitstream, not from this datapath.

## What follows

- **The gap to the papers is 6.3×**, not the ~21× previously stated: 159 SPS per
  channel against a specified 1000.
- **The passband claims still move.** At 159 SPS the σ₁ = 2 kernel is not a 2 ms
  kernel, and DoG_fast does not peak near 48 Hz.
- **`FS = 1000` is hardcoded** in `01_golden_model/ttcgs_golden_model.py`, which
  is where the 53.3 / 62.8 dB SNR figures come from, and in `make_paper_figs.py`,
  which resamples a capture onto a 1 kHz grid before filtering. Both therefore
  analyse a rate the hardware does not produce.
- **`STREAM_MODE = 1` (1 kHz UART) does not fix it.** The UART is not the binding
  constraint; each value would simply be repeated about six times.

## Raising the rate

**Continuous conversion mode is the wrong lever, and would make things worse.**
It removes the per-conversion START and the 219 µs start-up, but a mux change in
continuous mode contaminates the next conversion, which must be discarded:

```
continuous, DR=800   800 / 2 discarded / 4 channels  = 100 SPS per channel
single-shot, now                                       159 SPS per channel
```

`ads114s08_spi.v` also records that single-shot was adopted *because* continuous
mode produced intermittent `0x7F8D` (~+FS) rails at the mux boundary. Going back
costs twice.

**`DR` is the lever, and it is one constant.** `VAL_DR` 0x3A → 0x3D takes DR from
800 to 4000 SPS. Modelled from the measured budget — *not yet measured*:

| DR | if the 219 µs is fixed | if it scales with 1/DR |
|---:|---:|---:|
| 800 (now) | 159 SPS/ch (measured) | — |
| 1000 | 189 | 195 |
| 2000 | 304 | 348 |
| 4000 | **436** | **628** |

Which of the two columns applies is decided by one flash and one 2.5 s capture.
Even the optimistic column falls short of 1000 SPS per channel, so the choice
below still has to be made — but from 628 rather than 159.

The cost is noise: 800 → 4000 SPS raises RMS noise roughly 2×.

## Separately: the rate is not crystal-accurate

`EXT_CLK` is `1'b0`, so the device runs on its internal 4.096 MHz oscillator —
±2% accuracy, and *the data rate scales with oscillator variation*. TTCGS defines
its σ in samples, so the clock drifting drags the claimed passbands with it.
Driving CLK from the FPGA (27 MHz / 7 = 3.857 MHz, scaling every rate by 0.942)
makes it ±20 ppm and coherent with the LDC's CLKIN.

This needs the board to route FPGA → ADS CLK. **V1 does not.** It belongs on the
V3 review list.

## Still not decided

Three ways out, and the choice is a design decision rather than a bug fix:

1. **Make the hardware meet the spec.** Raise DR and absorb the noise, then
   re-measure. This is the only route that preserves the published numbers, and
   the measured budget says it does not reach 1000 SPS per channel on its own.
2. **Re-derive the numbers at the achieved rate.** Set `FS` to what the hardware
   does, regenerate the coefficients, and update the passband and settling claims
   in the papers. Cheap, honest, and it changes text in both manuscripts.
3. **Decouple them.** Keep σ in samples, state the sample rate as a parameter,
   and give the band centres as a function of it. Most defensible, most editing.

Nothing here is decided. Until it is, do not quote a frequency derived from
`FS = 1000` as a measured property of this hardware.

---

### Superseded text

Kept verbatim so the correction can be audited. Both claims below are wrong; see
"Two earlier conclusions, withdrawn" above.

> Measured, from `DATA/` (`2026-07-30_ADS_corner-marked_raw.csv`, 3861 rows at
> 97 rows/s):
>
> ```
> consecutive identical samples   ch0 72.1%   ch1 71.2%   ch2 70.9%   ch3 73.8%
> median run of identical values  2 rows
> => real update rate            ~48 SPS per channel,  ~192 SPS aggregate
> ```
>
> Not 800, and not 1000. The driver is single-shot: each channel waits out a full
> conversion before the next is started, so the four channels run in series with
> SPI overhead between them, and the aggregate lands roughly 20× below the
> specified figure.
>
> ## And TIME_MUX turns out to be load-bearing
>
> It is not an option. Measured 2026-08-06, same wiring, only this parameter
> changed:
>
> ```
> TIME_MUX = 0   ch0 converts once, then stops. ch1..ch3 never update at all.
> TIME_MUX = 1   all four channels update continuously, ~31-48 SPS each
> ```
>
> So the ADS driver only keeps running because something resets it every 300 ms.
> Whatever stalls it — the DRDY edge detector never seeing another falling edge is
> the leading suspect, since `S_WAITDR` waits on an edge and single-shot DRDY must
> return high before it can fall again — the periodic reset has been masking it,
> and every ADS capture in `DATA/` was taken under that reset.
>
> **Confirming the mechanism needs a scope on DRDY.** It is not diagnosable from
> the captured stream alone.
