# INAUSIS

A biomimetic dual-modal tactile sensing front-end: a chain-aligned magnetorheological
elastomer (MRE) skin read through two orthogonal channels, and a causal
Difference-of-Gaussians temporal encoder that runs on a single commodity FPGA.

The work is split into two companion manuscripts, both **in preparation**:

| Manuscript | Scope |
|---|---|
| **A Chain-Aligned Magnetorheological Elastomer for Range-Partitioned Dual-Modal Tactile Sensing** | the sensing material and the physics of its two readouts |
| **Temporal Tactile Causal Gaussian Splash (TTCGS)** | the signal-processing front-end that consumes them |

They make independent claims and are validated independently. Neither is evidence
for the other.

---

## The idea in one paragraph

A fingertip has to resolve a 0.1 kPa brush *and* survive a 335 kPa power grasp.
No single transduction mechanism does both. Here one material provides two:
below ~6 kPa, compression narrows the nanometre-scale gaps between field-aligned
nickel chains and field-emission conduction drops the resistance by orders of
magnitude; above ~6 kPa the chains have collapsed into near-metallic contact, the
piezoresistive sensitivity vanishes, and the same compression is read inductively
through the effective permeability the chains present to a PCB planar coil. The
handover point is not a design parameter — it is the pressure at which dR/dP → 0.

Downstream, the front-end **encodes rather than measures**: three causal Gaussian
scales aligned with the SA-I / FA-I receptor bands, a z-score significance flag per
dimension, and a single-wire Manchester link with a CRC-protected reverse channel
so the consumer can rewrite the thresholds. Curve fitting, calibration, and
cross-channel feature combination are deliberately *not* done in hardware.

> Hardware only encodes; the downstream agent decides.

---

## Repository layout

```
CODE/V1/
  02_rtl_production/     synthesizable RTL (DoG, z-score flag, framer, Manchester, reverse LUT parser)
    impl/gwsynthesis/    GowinSynthesis reports for the above
  03_rtl_testbenches/    testbenches + .mem stimulus, run_regression.sh
  06_bringup_legacy/     ADS114S08 / LDC1101 SPI bring-up cores and traces
DATA/                    captured waveforms and figures
MRE/V1/                  elastomer formulation and process notes
PCB/V1/                  X004 board: Gerber, BOM, pick-and-place
PCB/V3/                  next revision
```

---

## Status

Status codes follow the manuscripts: **D** designed · **R** RTL implemented ·
**V** verified on hardware · **F** fabricated · **B** bring-up pending ·
**E** estimated.

### Digital front-end (TTCGS)

| Item | State |
|---|---|
| Full bidirectional datapath (`ttcgs_sys`) | **R** — RTL complete |
| Simulation vs bit-exact fixed-point golden model | **V** — 12/12 regression pass |
| Synthesis, place & route, timing closure | **V** — but see the caveat below |
| Streaming real samples from both converters | **V** |
| Measured DoG waveforms under controlled loading | **B** |

Post-route on GW1NR-LV9QN88PC6/I5 at the native 27 MHz crystal (no PLL):

```
3334 logic cells   2107 registers   5 BSRAM   4 DSP
Fmax 45.6 MHz      setup/hold violations: 0
```

> **Reported, but not evidenced by anything committed here.** The `ttcgs_board`
> place-and-route output was overwritten by later bring-up builds — Gowin writes
> every target into one `impl/` directory, so synthesising a different top
> silently destroys the previous target's reports. What is in
> `CODE/V1/02_rtl_production/impl/pnr/` is a `top_dual` bring-up run from
> 2026-08-01 (Logic 1000/8640, Register 633/6693), a different design entirely.
> See [impl/README.md](CODE/V1/02_rtl_production/impl/README.md) for how to
> regenerate the real run.

The reverse channel costs **+274 logic cells (+10.6%)** over the forward-only
datapath — closing the inference-to-sensing loop is essentially free.

Fixed-point analysis: Q15 coefficients with a 39-bit accumulator preserve the
subtractive cancellation inherent to a difference of Gaussians at **53.3 dB**
(DoG_fast) and **62.8 dB** (DoG_slow) SNR. Against a 16-tap moving-average
differential, the causal-Gaussian kernel gives **≈12 dB additional attenuation at
300 Hz** with no sidelobe ripple.

Power is projected, not measured: ~23 mW analog + ~36 mW FPGA core
(post-route Gowin Power Analyzer) ≈ **60 mW design power**. The Tang Nano 9K
development board adds ~250 mW of non-design overhead (USB bridge, LEDs,
on-board regulators), so a measured-context upper bound is ≈0.27 W.

### Analog front-end

| Item | State |
|---|---|
| ADS114S08 link (register read-back + write/read-back) | **V** |
| ADS114S08 streaming 16-bit signed conversions | **V** — but at ~48 SPS/channel, not the specified 1 kSPS; see [SAMPLE_RATE.md](CODE/V1/SAMPLE_RATE.md) |
| LDC1101 link (CHIP_ID 0xD4, WREG/RREG round-trip) | **V** |
| LC tank oscillating, stable L against ±2 LSB baseline | **V** |
| Bare-coil material discrimination by sign of ΔL | **V** |

The three-condition bare-coil test (no target / fingertip / metal coin) separates
conductive from non-conductive targets by the **sign** of ΔL: fingertip +26 LSB
against a 678 LSB baseline, metal coins −20 to −24 LSB. Two limits are stated
explicitly: the test does not resolve whether the positive branch is permeability
or dielectric loading, and the ΔL > 0 verified here is a fingertip in *proximity*,
not the elastomer under *compression*.

### Sensing material — the open gate

The formulation and process are fixed; the physical analysis of both channels is
complete. What is **not** yet done is the characterization of the fabricated skin:

- **R(P)** — piezoresistive curve vs. model fit
- **L(P) and RP(P)** — inductive curves under controlled compression
- **cyclic drift** — R and L baselines vs. cycle count

The **principal open risk** is quantified rather than hidden: a sensitivity budget
computed with the modulus of the *filled* composite projects the coil-level
response at the 6 kPa crossover at 0.02–0.12%, against a ≈0.13% bound set by the
≈13× tank-level dilution from the series inductor and the converter's resolution
floor. On the present estimate the inductive response sits *below* that bound,
implying a narrow blind band between the channels rather than an overlap. Two
recovery levers exist if the margin proves insufficient — electrical (raise the
coil's self-inductance, shrink the series inductor; the dilution is a layout
quantity, not a physical limit) and material (plasticizer content and fill
fraction both lower the composite modulus).

---

## Bring-up notes

Hard-won, and not obvious from the datasheets:

- **The LDC1101 is SPI Mode 0**, not Mode 3. Mode 3 returns CHIP_ID = 0xFF.
- **Read STATUS (0x20) *after* the RP/L data registers**, not before.
- A floating MISO reads 0xFF, and 0xFF sets the NO_SENSOR_OSC bit — so a dead SPI
  link is indistinguishable from a stalled tank unless you also watch CHIP_ID.
  Re-reading CHIP_ID every sample loop is what separates the two.
- The ~13–15-sample alternation visible in the STATUS column is the **DRDYB
  conversion cadence** beating against the print period. It is normal.
- `RP_SET` brackets the tank: 0x46 (RP_MIN 1.5 kΩ / RP_MAX 6 kΩ) gives
  ~19 counts/Ω on a ~2.2 kΩ tank. Widening to 0x47 halves the resolution for no
  measured benefit.
- **The `fCLKIN > 4·fSENSOR` rule is a resolution guideline, not an aliasing
  limit.** In RP+L mode the sensor gates a counter that counts CLKIN, so a low
  CLKIN costs counts, not correctness; the `SENSOR_DIV` workaround exists only in
  LHR mode. Do not contort the tank to satisfy it — `RP ∝ 1/C`, so adding tank
  capacitance to lower fSENSOR collapses RP below the converter's 1.25 kΩ floor.
- Keep ground pour **≥30% of the coil diameter** away from the coil (SNOA930 §4.2.1).

Toolchain, for Gowin + Tang Nano 9K:

- `programmer_cli` needs an explicit `--location`. The FT2232 exposes two USB
  interfaces and only one is JTAG; without it the cable resolves to `None` and the
  tool **hangs, ignoring Ctrl+C**. The location number changes with the USB port.
- A hung `programmer_cli` keeps the USB handle — closing the terminal does not kill
  it, and every later attempt then fails with `Cable open failed`.
- **Do not run Zadig on this board.** Its libwdi drivers fight FTDI's and leave the
  device at `CM_PROB_FAILED_START` (code 10).
- `--run 2` is SRAM and is lost on any power blip; the FPGA then silently reloads
  an *older* bitstream from flash. Use embedded flash (`--run 6`) for anything long.

---

## Reproducing the simulation results

```sh
cd CODE/V1/03_rtl_testbenches
./run_regression.sh
```

Icarus Verilog with `-g2012`. Verilator does not work — the benches use `#` delays
and hierarchical memory peeks.

---

## Status of this repository

This is a research repository accompanying two manuscripts in preparation. The RTL
is complete and verified in simulation and on silicon; the sensing material is
formulated but not yet characterized. Figures marked as placeholders in the
manuscripts correspond directly to the measurements listed as open above.

## Licence

Dual-licensed, and deliberately so:

- **Software** (`CODE/**`) — PolyForm Noncommercial 1.0.0
- **Everything else** (`DATA/`, `MRE/`, `PCB/`, docs, figures) — CC BY-NC 4.0

Research, teaching, and personal use are unrestricted. Attribution is required,
and it travels: nobody can grant rights they do not hold, so anyone using this
material as part of someone else's larger work still needs a licence for the part
that originated here. There is **no ShareAlike** term — it would burden anyone
integrating this into a larger design without adding any protection that
attribution and the noncommercial term do not already provide.

See [LICENSE](LICENSE.md) for what the licence does and does not do — in particular,
it governs reuse, not citation chains.

### Commercial use — the doorbell is answered

Commercial use is **not** granted by the public licence, and that is not a closed
door. It is an open one with a doorbell.

If you want to use any part of this in a product, a funded evaluation, or an
industrial research programme, write to **sigmansslee@gmail.com**. Say which parts
interest you (the elastomer, the front-end architecture, the RTL, or the whole
stack) and what you intend to build.

**Terms are negotiable and enquiries get a reply.** I am the sole copyright
holder, so I can grant commercial terms directly — there is no institutional
approval chain in the way, and no technology-transfer office to route through.
The noncommercial clause exists to make this a conversation, not to prevent one.

## Contributing

Issues, reproduction reports, and corrections are very welcome — especially from
anyone who builds the elastomer and measures something different. Code pull
requests are not accepted, for reasons given in [CONTRIBUTING.md](CONTRIBUTING.md).

## Citing this work

Use the **Cite this repository** button, or see [CITATION.cff](CITATION.cff).
If you use one half, cite the manuscript for that half — the material paper for
the elastomer and its dual-modal physics, the TTCGS paper for the
signal-processing front-end.

## Contact

Pin-Han Li — Independent Researcher, Hsinchu, Taiwan
sigmansslee@gmail.com
