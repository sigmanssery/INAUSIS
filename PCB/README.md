# PCB / V1 — X004 prototype board

The board all measured results in this repository were taken on.

| | |
|---|---|
| Revision | X004, 2026-04-01 |
| Stack | 4-layer FR4, 43 × 32 mm |
| Assembly | JLCPCB |
| Files | `Gerber_X004_PCB_X004_2026-04-01.zip`, `BOM_X004_2026-04-01.csv`, `PickAndPlace_PCB_X004_2026-04-01.csv` |

The IC area is reinforced with an FR4 stiffener for soldering reliability.

## What is on it

| Part | Role |
|---|---|
| **ADS114S08** (VQFN-32) | 4 single-ended divider midpoints, 1 kSPS each, PGA bypassed |
| **LDC1101** (VSON-10) | planar coil in RP+L mode |
| **LT1763** (MSOP-12) | 3.3 V ultra-low-noise analog rail, 20 µV_rms |
| planar spiral coil | 6 × 10 mm, ~10 turns, 6 mil trace / 4 mil gap, ~0.4 µH |
| divider pads | fixed 100 kΩ 1% in series with each sensing element |

The digital side is a Tang Nano 9K (GW1NR-LV9QN88PC6/I5) on flying leads; a single
USB-C supplies 5 V, FPGA programming, and the debug UART.

**Supply partitioning:** the FPGA uses the Tang Nano's own regulators, the analog
side uses the dedicated LT1763. The two domains share ground but no supply rail,
keeping digital switching noise off the analog rail.

## The LC tank

The bare coil is only ~0.4 µH with Q < 10 — below the LDC1101's minimum tank-Q
requirement — so a 4.7 µH 0402 inductor (DCR 0.55 Ω) is added in series, bringing
the total to 5.1 µH. With a 220 pF C0G shunt and ~15 pF of coil and layout
parasitics the tank resonates near **4.6 MHz**.

Q ≈ 59 is a DCR-only upper bound; core and skin-effect losses of the multilayer
0402 inductor at this frequency put the realized tank Q closer to 20–40, still
inside the converter's supported range.

**The series inductor is also the board's main limitation.** It contributes 4.7 of
the 5.1 µH, so any change in the *coil's* inductance — which is the thing the skin
actually modulates — is diluted ≈13× before the converter sees it. See `MRE/V1` for
what that costs and how the next revision recovers it.

## Known issues carried into V3

- **Ground pour is far too close to the coil.** TI's SNOA930 §4.2.1 asks for no
  copper within 30% of the coil diameter; this board's keep-out is about 8%. Close
  pour suppresses RP directly, which is very likely why the measured tank RP sits
  below what the geometry predicts.
- **The 13× tank dilution** above — a layout quantity, fixable by raising the coil's
  self-inductance (more turns, stacked layers) and shrinking the series inductor.
- **LT1763 output capacitance.** This regulator requires a *minimum* ESR; paralleled
  ceramics (≈5 mΩ) sit below it and put the loop near instability. Symptoms were
  audible whine and marginal behaviour with both converters loaded. Either fit an
  output cap with appropriate ESR, or put 0.5–1 Ω in series with a ceramic one.
  V3 moves to a ceramic-stable regulator.
- **Cross-board signal lines have no series resistance.** When one board is powered
  and the other is not, the FPGA back-powers the unpowered IC through its I/O ESD
  diodes. This has repeatedly left the LDC latched up and unresponsive, recoverable
  only by disconnecting *both* the supply and every signal wire and waiting ~30 s.
  **100–330 Ω in series on each cross-board line** caps the diode current and makes
  power sequencing irrelevant.

## Coil geometry note

The coil is rectangular. A circular spiral gives the best Q and lowest Rs for a
given area (SNOA930 §2.1); the rectangular choice here is a footprint compromise,
not an optimization. Mutual inductance between stacked layers raises L *without*
raising Rs, which makes layer count the cheapest lever on Q available in the next
revision.
