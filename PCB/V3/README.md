# PCB / V3 — next revision

In design. Nothing here has been fabricated or measured; every number below is a
target or a calculation, not a result.

## What V3 is for

V1 (`../V1`) works and produced every measured result in this repository, but it
carries four defects that are layout problems rather than physical limits. V3
exists to remove them.

| V1 defect | V3 intent |
|---|---|
| ground pour ~8% of coil diameter away | keep-out widened to **≥30%** per SNOA930 §4.2.1 |
| 4.7 µH series inductor dilutes coil ΔL by ≈13× | raise coil self-inductance, shrink or remove the series part |
| LT1763 needs minimum ESR; paralleled ceramics destabilize it | **LDLN025** — ceramic-stable, C_OUT ≤ 10 µF |
| no series resistance on cross-board signals | **100–330 Ω** on each line, capping ESD-diode back-powering |

## Coil

Measured from the V1 Gerber, the sensing coil is 4 layers × 7.5 turns, 0.152 mm
trace / 0.229 mm gap, outer 7.62 mm, R_dc 1.96 Ω at 1 oz.

At a fixed resonant frequency, `Q = 2πf·L / Rs`, and for a planar spiral
`L ∝ n²·d_avg` while `R ∝ n·d_avg/w`. So **Q ∝ n·w** — and since turns and width
compete for the same radial space, the real lever is the ratio **w/(w+s)**. V1
spends only 0.399 of its radial budget on copper.

A candidate geometry, held to the same keep-out and 1 oz copper:

| | V1 | candidate |
|---|---:|---:|
| trace / gap | 0.152 / 0.229 mm | **0.230 / 0.127 mm** |
| outer diameter | 7.62 mm | 8.20 mm |
| turns per layer | 7.5 | 8.0 |
| w/(w+s) | 0.399 | **0.644** |
| R_dc | 1.86 Ω | 1.47 Ω |

Tightening the gap alone — 0.229 → 0.127 mm, which is standard 5 mil and costs
nothing — is the single largest contributor.

**Two constraints that are easy to get backwards.** First, `RP = L/(Rs·C)`, so
`RP ∝ 1/C`: adding tank capacitance to lower the sensor frequency collapses RP,
and the LDC1101 needs RP ≥ 1.25 kΩ and Q ≥ 10. Second, the datasheet's
`fCLKIN > 4·fSENSOR` is a **resolution** guideline, not an aliasing limit — in RP+L
mode the sensor gates a counter that counts CLKIN, so a low CLKIN costs counts, not
correctness. Do not distort the tank to satisfy it.

Circular beats rectangular for Q at equal area, and mutual inductance between
stacked layers raises L without raising Rs — layers remain the cheapest lever.
For a **contact** application like this one the usual `d_IN/d_OUT > 0.3` guidance
does not apply; ratios down to 0.05 are fine and the inner turns add sensitivity.

## Sensor capacitor

C0G/NP0 only, placed as close to the coil as the layout allows, with a spare
parallel pad for trimming. Inter-layer parasitics on a 4-layer stacked spiral add
tens of pF to the nominal, so the fitted value should be chosen after measuring the
first article rather than before.

## Spare pins

Three positions are broken out, each with a board-side pull that defines a safe
state while the FPGA is still configuring:

| Signal | Pull | Safe default |
|---|---|---|
| `ADS_RESET` | 10 k up to IOVDD | not reset (active low) |
| `LDO_EN` | 100 k up to VIN | rail on |
| `ADS_CLK` | down to DGND | ADS uses its internal oscillator |

Ordering them to match the FPGA header lets the harness run straight, which
shortens every loop and removes a class of crosstalk that crossed wires invite.

## Status

Design only. No Gerber, BOM, or pick-and-place is published here yet — they will
land when the revision is frozen.
