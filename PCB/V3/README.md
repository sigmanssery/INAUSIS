# PCB / V3 — a small sensor board and an evaluation compute board

In design. Nothing here has been fabricated or measured; every number below is a
target, a calculation, or a measurement taken on **V1** hardware, and each is
labelled as such.

The defining decision of this revision is in the name: the two boards are allowed
to have different goals. The sensor board is as small as the physics permits; the
compute board stops trying to be small and becomes an instrument.

V3 splits the design in two: a **sensor board** carrying the coil, the tank
capacitor and the four dividers, and a **compute board** carrying the ADS114S08,
the LDC1101 and the regulators, joined by a 10-way FPC.

---

## Two boards, two sets of constraints

The split is not just packaging — it decouples two requirements that were fighting
each other on V1, and they should be allowed to diverge.

**The sensor board must be small.** The coil has to couple to the elastomer at
contact scale, and SNOA930 §4.2.1 wants ground pour at least 30% of the coil
diameter away, which on a 7.62 mm coil means a 12.2 mm keep-out. On a 20 × 20 mm
outline that leaves under 4 mm a side for everything else. This board is on the
gripper and its size is set by physics.

**The compute board has no such constraint, and should stop pretending it does.**
It holds two converters and a regulator, it plugs into the FPGA, and it sits on the
bench — the FPC is what reaches the gripper. Its 21 × 26 mm outline was inherited
from the shield form factor, not from any requirement, and a shield only has to
reach the header pins.

So the compute board becomes an **evaluation board**: large, fully instrumented,
and reworkable by hand.

### Why that is the right trade

Almost everything that has cost this project time was a hardware-maintainability
problem found only after fabrication:

| | |
|---|---|
| LDC latch-up from back-powering through signal lines | no series resistance |
| "the two chips cannot run at once" | LT1763 ESR instability, one shared rail |
| 32% bad SPI reads, forcing a 4× clock reduction | dupont harness |
| CLKIN wire working loose, intermittent faults | dupont harness |
| 13.5 MHz CLKIN killing the tank | routing |
| AINCOM tied to local ground instead of a sense line | schematic |
| 100 kΩ divider against a >200 MΩ sensor | wrong value, unchangeable |
| ground pour at 8% of coil diameter | routing |
| **needing to mirror SPI onto spare FPGA pins to get a probe on it** | no test access |

That last one happened while taking the logic-analyser capture in
[`DATA/`](../../DATA): there was nowhere on the board to attach a probe, so the
signals had to be duplicated onto unused FPGA pins and captured there. Three board
revisions in, the instrument access is still the bottleneck.

The bare-board cost of 50 × 50 mm versus 21 × 26 mm is nil at these quantities. The
expensive parts are the ADS114S08 and the assembly setup, and neither scales with
area.

**A larger board does not endanger CLKIN.** With 470 Ω slowing the edge to ~7.2 ns
(below), the critical length for reflection becomes
`7200 ps / (6 × 6.9 ps/mm) ≈ 174 mm` — a 100 mm board is still well inside it. And
because the coil now lives on the other board, more area makes it *easier* to keep
CLKIN away from the FPC connector.

---

## The gate: CLKIN routing

**Measured on V1, 2026-07-30.** Raising the LDC's CLKIN from 3.375 to 13.5 MHz on
the dupont prototype made the LDC return `RP/L = FFFF` immediately — the LC tank
stopped oscillating. Dropping back restored it. Two alternative explanations were
tested and eliminated: reseating every neighbouring pin improved SPI but 13.5 MHz
still failed, and setting `MIN_FREQ = 0` to rule out a CLKIN-scaled watchdog still
failed.

This matters because `fCLKIN ≥ 4·fSENSOR` is what buys L resolution. V1 violates it
by 6× (3.375 MHz against a 5.08 MHz sensor), and that is why `L_DATA` has always sat
at ~1361 counts — **2.1% of full scale**.

> **CLKIN routing is a requirement, not a guideline.** On the compute board that
> means keeping it away from the FPC connector's `COIL` pins and from the INA/INB
> traces, guarded both sides, with its series resistor **at the source** (see
> below). Without this, 13.5 MHz is unusable, the 4× rule can never be met, and
> every figure in the "what this buys" table at the end is unreachable.

---

## Sensor board — locked by the Gerber

| # | Item | Value | Why |
|---|---|---|---|
| 1 | **Ground keep-out around the coil** | **≥ 12 mm** across | SNOA930 §4.2.1 asks ≥30% of coil diameter; V1's silk keep-out is 8.890 × 9.144 mm on a 7.62 mm coil ≈ 8%. Close pour suppresses RP directly. |
| 2 | **Tank capacitor footprint** | 3 parallel 0805 C0G/NP0 50 V positions, **beside the coil** | **V1 has no footprint at all** — without it the FPC sits inside the resonant loop. Three positions allow 470 / 560 / 680 pF to be settled on the first article. |
| 3 | **Layer count** | **4, not 6** | V1's Inner4 and Bottom carry no traces at all — the coil uses four conductor layers. Largest single cost saving in the project. A thin 0.8–1.0 mm stack also couples better between layers, so L comes out slightly higher. |
| 4 | **Copper weight** | **1 oz** | skin depth at 2.96 MHz is 38.4 µm; 1 oz is already 34.8 µm. 2 oz takes Q from ~27 to ~30 and is not worth paying for. 0.152 mm / 0.229 mm geometry is also below most 2 oz inner-layer minimums. |
| 5 | **Divider resistors** | **1 MΩ**, **0805**, 25–50 ppm/°C, **3 parallel positions per channel** | see below |
| 6 | **Cable shield** | must stop **≥ 10 mm short of the coil** | measured: aluminium foil near the coil moves L −1%, RP −1.8%. A shield reaching the coil is a permanent eddy-current target. |
| 7 | **AINCOM** | routed as a **sense line** to the star point where the four divider grounds meet | V1 ties AINCOM to local ground beside the ADS while the dividers ground at the sensor end; any current in that ground becomes measured signal |

---

## Compute board — an evaluation board

Same schematic, same parts, a larger outline and full instrumentation. Nothing here
changes what the board *does*; all of it changes how fast a problem can be found.

### 1. Do not bury the FPGA headers

A larger board stacked on the Tang Nano covers its pin headers. The budget is
tighter than it looks, so it is worth counting properly.

The board breaks out **45 of the 88 package pins**. The left header is 24 pins and
**every one of them is already committed**:

```
36 37 38 39 │ 25 26 27 28 29 30 │ 33 34 40 35 41 │ 42 │ 51 53 │ 54 55 56 │ 57 68 69
 spare/microSD     ADS SPI            LDC SPI      line   mirror   SSPI ✗    mirror
```

The right header is mixed-voltage, which is the trap:

```
pos   1 │  2  3  4  5  6  7  8  9 │ 10 11 12 13 14 15 16 17 │ 18 │ 19 20 21 22 │ 23  24
pin  63 │ 86 85 84 83 82 81 80 79 │ 77 76 75 74 73 72 71 70 │ 5V │ 48 49 31 32 │GND 3V3
     3.3      <---- 1.8 V ---->         <---- 3.3 V ---->            <- 3.3 V ->
```

| | Count | Which |
|---|---:|---|
| free 3.3 V | **13** | `63 70 71 72 73 74 75 76 77 48 49 31 32` |
| 1.8 V (bank 3) | 8 | `79–86` — cannot drive a 3.3 V peripheral |
| free on the left header | **0** | fully committed |

> ⚠ Pins 79–86 sit between two 3.3 V groups on the same header. Any fan-out must
> label bank voltage per pin, or someone eventually wires a 3.3 V signal into a
> 1.8 V bank.

**But this revision hands seven pins back.** Two of the left header's commitments
exist only because the present board lacks the features this one adds:

| Pins | Currently | On this board |
|---|---|---|
| `51 53 57 68 69` | debug mirrors — SPI duplicated onto spare pins because there was nowhere to probe | **J_DIG replaces them; 5 pins returned** |
| `39 41` | pseudo-grounds, FPGA I/O driven low, because the only real GND is on the far header | **a real ground plane returns 2 more** |

So the working budget is **13 (right header) + 7 (returned) = 20 free 3.3 V pins**,
and a full fan-out is not needed — only the idle ones need re-exposing, with pins
still in use going to J_DIG.

This ends up better than the original rather than a workaround. The Tang Nano's own
silkscreen is cramped enough that identifying pins during the logic-analyser session
meant counting header positions by hand. A fan-out on your own board can print
`P51 / dbg_drdy` beside the pin.

> ⚠ **Do not stub CLKIN, or anything routed near the tank.** A fan-out is an open
> stub — an antenna and a reflection point on precisely the signal being kept quiet.
> The rule: fan out idle pins freely; signals in use go only to J_DIG, with the
> branch taken **after** the series resistor and kept under ~10 mm.

**One covered signal gets its own connector: `line`, the Manchester link.** It is
pin 42 on the left header, so the rule above requires re-exposing it — and it is
worth four labelled positions rather than a slot on the general expansion header,
because it is the interface to the downstream consumer:

```
J_LINK (1×4)     line (P42) · 3V3 · GND · reset
```

Any MCU dev board connects with four jumper wires. This is what makes the
closed-loop demonstration in [ROADMAP.md](../../ROADMAP.md) possible without
committing to an MCU footprint now — and closing that loop is what would take the
bidirectional datapath from **R** to **V** in the top-level status table.

### 2. Probe access

The logic analyser available to this project has dupont leads, not probes, so test
access has to be **2.54 mm pin header**, and every signal needs a ground beside it.
Two double-row headers, bottom row entirely ground:

| Header | Top row |
|---|---|
| **J_DIG** (2×10) | SCLK · DIN · DOUT · CS_ADS · CS_LDC · DRDY · ADS_RESET · ADS_CLK · LDC_CLKIN · LDO_EN |
| **J_ANA** (2×10) | AIN2 · AIN3 · AIN4 · AIN5 · AINCOM · TANK_A · TANK_B · 3V3_ADS · 3V3_LDC · 5V_IN |

> ⚠ The AINCOM test point must be a **high-impedance measurement stub only**. If it
> becomes a second return path it destroys the entire point of the sense line.

### 3. Series resistor positions — 11, all 0805

Every FPGA↔peripheral line gets one, **default 470 Ω**, footprint present so 0 Ω or
any other value can be fitted later:

```
SCLK · DIN · DOUT · CS_ADS · CS_LDC · DRDY
ADS_RESET · ADS_CLK · LDC_CLKIN · LDO_EN
```

**470 Ω is one part number for all of them**, and it is the right value on both
criteria. As a back-powering limit it caps ESD-diode current at
`(3.3 − 0.7) / 470 = 5.5 mA`, comfortably under the ±10 mA these TI parts specify —
where 220 Ω gives 11.8 mA, marginally over. As an edge-rate limiter on CLKIN it
gives `t_r = 2.2RC ≈ 7.2 ns` against ~7 pF of load, dropping dV/dt from 1.65 to
0.46 V/ns — a 3.6× reduction in the quantity that couples into the tank.

Speed is not a concern anywhere: 7.2 ns is 9.7% of the 13.5 MHz CLKIN period, 4.9%
at ADS_CLK, and under 3% on SPI even if `CLK_DIV` returns to 14. The RC is symmetric
and CMOS thresholds sit mid-supply, so the 40/50/60% duty specification is
unaffected.

Dissipation is a non-issue and is **independent of R** — the energy per edge is
½CV² regardless: `P = C·V²·f = 7 pF × 3.3² × 13.5 MHz ≈ 1.0 mW` against a 0402's
62.5 mW rating. Even a sustained back-powering fault is `(3.3−0.7)²/470 = 14 mW`.

> **Place the CLKIN resistor at the source**, where the signal enters from the FPGA
> header — not at the LDC. The coupling problem has CLKIN as the *aggressor*, and
> the emitting length is the trace upstream of the resistor. A resistor at the load
> end protects the LDC from incoming noise but leaves the whole trace switching at
> full rate.

### 4. Power architecture

Directly derived from the V1 LT1763 failure, where one regulator feeding both chips
lost phase margin under load and oscillated audibly.

| Item | Spec |
|---|---|
| **One LDO per chip** | LDLN025 × 2 — ADS and LDC on independent rails |
| **Three-way jumper per rail** | LDO output / FPGA 3V3 / disconnected |
| **Current shunt per rail** | **1 Ω 1% 0805**, with a test point each side |
| `C_OUT` | ≈1 µF, **a single ceramic** — LDLN025 has an ESR *floor* of 5 mΩ and two parallel 0603s fall below it |
| Bulk storage | on the **input** side, 47 µF **10 V or 16 V** — `C_IN` has no upper limit, `C_OUT` does |

The shunts are worth their board area on their own: the repository currently states
analog power as *"~23 mW, projected, not measured."* At 7 mA across 1 Ω that is
7 mV, which any multimeter resolves to ±0.1 mA. **It turns a projection into a
measurement.**

#### The incoming supply filter

One ferrite bead on the 5 V as it enters, ahead of both LDOs:

| | |
|---|---|
| package | **0805** — matches the rest of the board, better current rating and lower DCR than 0402 |
| impedance | **600 Ω @ 100 MHz**, the common default and the cheapest to stock |
| rated current | **≥ 500 mA** against a ~50 mA load — 10× margin |
| DCR | **≤ 0.15 Ω** → under 10 mV of drop at 50 mA |

**A parallel 0 Ω pad beside it.** Fit the bead, or short it out, and measure the
difference — which turns "is the bead doing anything?" from an article of faith into
a two-minute experiment. That is the whole point of this board.

**A Pi filter is not worth building, but leave the pad for one.** The heavy lifting
is already done by the two separate LDOs: 60–70 dB of PSRR at low frequency, far
more than any passive network here contributes. A bead adds first-order roll-off
above where PSRR fades, which is the gap worth covering, and a Pi adds a second
reactive element — plus an LC resonance that can show *gain* if the bead is still
inductive rather than resistive at that frequency. That is a classic way to make a
supply noisier while believing it has been filtered.

More to the point: **the noise that has actually hurt this project was not conducted
through the 5 V rail.** It was CLKIN coupling into the tank and the ground return
impedance in §5. A Pi filter addresses neither.

Since `C_IN` already sits downstream of the bead, adding **one unpopulated 0805
capacitor position upstream** makes the topology a Pi whenever that is wanted. One
empty pad buys the option; populating it now buys a resonance to think about.

### 5. Grounding, and the single return pin

The header exposes exactly **one** ground. Every return current between the two
boards passes through it, and a large low-impedance plane on the compute board does
not help, because the bottleneck is the pin, not the plane.

A 2.54 mm header pin, ~10 mm of 0.64 mm² brass through a mated socket:

```
conductor    rho*L/A = 7e-8 * 0.01 / 4.1e-7   ~  1.7 mohm
contact      socket spec, typically            <   20 mohm
                                               ------------
DC total                                       ~   20 mohm
inductance   single conductor, large loop      ~   10 nH
```

**The DC offset does not corrupt the analog measurement.** If the board draws 30 mA
from the FPGA rail, the supply return develops 0.6 mV across that pin — 8 LSB at
76 µV/LSB, which sounds alarming. But the ADS references AINCOM, which is a sense
line to the sensor board's star point, so an offset between the two boards' grounds
is **common-mode and subtracted**. That is exactly what the AINCOM fix is for.

**The AC behaviour is the real concern**, because `V = L·di/dt`:

| | di/dt | ground bounce |
|---|---:|---:|
| CLKIN with the 470 Ω, 7.2 ns edge | ~1e6 A/s | **10 mV** |
| three SPI lines switching, no series resistors | ~1.2e7 A/s | **120 mV** |

Both sit under LVCMOS33's ~0.4 V noise margin, so the digital link is safe. The LC
tank is not: it is a high-Q resonator at 2.96 MHz, and ground bounce puts energy
straight into its band. **This is part of the mechanism behind the 13.5 MHz CLKIN
failure** — a long, inductive return path makes the whole loop an antenna.

**The structural version of the problem is worse than the pin.** Every ADS and LDC
signal is on the *left* header and the only ground is on the *right*, so every
return crosses the entire board. That is why the present design drives pins 39 and
41 low as pseudo-grounds — it was forced by the header layout, not chosen.

*Measured context, so this is not over-weighted:* the one-hour soak on the dupont
harness — worse wiring than this board will have — returned **100.000% valid
samples, L sd 0.647, ADS noise ±1.5 counts**. The ground return is a known
structural weakness, not a present fault.

**The fix is to stop sending supply current through it.** Give the compute board its
own supply — an added position on the rail jumper, or its own USB connector — and
the pin carries only signal return:

```
from the FPGA rail   30 mA * 20 mohm = 600 uV
independently fed    ~1 mA * 20 mohm =  20 uV     30x better
```

No extra component, and the jumper it needs is already in the spec. The 470 Ω series
resistors and the shared `periph_en` handle the back-powering that two independent
supplies would otherwise create.

Worth adding as well: a short braid from the compute board's ground to the Tang
Nano's USB-C or HDMI shell, and mounting both boards to one metal base plate — the
standoffs in §9 can do double duty.

#### What not to do

Three pieces of conventional advice are wrong here, and one is actively harmful.

**Never put a ferrite bead in the ground path.** The problem just diagnosed is that
the return is too impedant; a bead adds impedance to exactly that path.

| bead type | DCR | vs the 20 mΩ pin |
|---|---:|---:|
| typical 0402, 600 Ω @ 100 MHz | 0.35 Ω | **17× worse** |
| low-DCR, 120 Ω @ 100 MHz | 0.05 Ω | **2.5× worse** |

**Do not split the plane into AGND and DGND.** The `AGND` / `DGND` pin names on a
data converter refer to the *die's* internal grounds, not to a requirement for two
external planes — Kester's MT-031 and Ott's mixed-signal layout work both say so.
High-frequency return current flows directly beneath its trace because that is the
lowest-impedance loop; cut the plane and the return has to detour around the gap,
which multiplies loop area. Any signal crossing a split creates the antenna the
split was meant to prevent.

**A 0 Ω link between the two halves is only meaningful if you split them**, so it
does not apply.

#### Where the star point *is* correct

Star grounding is a low-frequency technique — useful below roughly 1 MHz, above
which plane inductance dominates and return current goes where it likes regardless.
With 13.5 MHz CLKIN and a 2.96 MHz tank, the RF side needs a solid plane.

But the piezoresistive path is DC to a few hundred Hz, squarely inside where star
grounding works — and the design already applies it correctly, as the AINCOM sense
line to the point where the four divider grounds meet. **Both techniques are in use;
each in the frequency range where it is valid.**

#### Where a ferrite *is* right

On the incoming supply, never on the ground:

```
5V from header ──[bead]──┬── LDO_ADS ── 3V3_ADS
                         └── LDO_LDC ── 3V3_LDC
```

It filters conducted noise from the FPGA side without touching the return path. It
is a secondary measure, though: the per-chip LDOs already give 60–70 dB of PSRR at
low frequency, far more than a bead contributes.

### 6. Divider and buffer flexibility

- **Three parallel 0805 positions per channel** so 100 kΩ / 1 MΩ / 10 MΩ can be
  swapped without a respin — the material's working resistance is not settled.
- **A quad op-amp in a DIP-14 socket**, with 0 Ω bypass links: populate it for a
  buffered front end, or fit the links for the present direct connection. Both
  architectures on one board.

A socket, and the only through-hole active part on the board, because this is the
component most likely to need swapping — MCP6004, TLV2374 and OPA4197 differ
substantially in input bias current, noise, and how close to the rails they actually
go, and which suits this sensor is not yet known. Socket insulation resistance is
>10¹² Ω against a 1 MΩ source, six orders of magnitude away from mattering.

> **Why nothing else is through-hole.** The ADS114S08, LDC1101 and LDLN025 have no
> through-hole option at all, so the board needs SMT assembly whatever else is done
> — which removes the usual argument for DIP, since you cannot avoid the reflow
> step anyway. Through-hole passives would also put several millimetres of exposed
> lead on the high-impedance AIN nodes, where the concern is capacitive pickup area
> rather than lead inductance.

### 7. Tank access

- INA / INB brought out to a 2-pin header so the oscillation can actually be scoped.

> ⚠ A 10× probe is ~10 pF, which against a 560 pF tank is 1.8% and shifts fSENSOR
> by ~0.9%. Fine for diagnosis; **do not derive calibration constants from readings
> taken with a probe attached.**

### 8. External sensor input

A 2.54 mm header or screw terminal wired in parallel with the FPC's AIN group, so a
commercial FSR can be connected directly without going through the sensor board.
This is what makes the open question in the last section answerable with hardware
that already exists.

### 9. Mechanical and practical

- **0805 passives throughout** — hand-reworkable
- silkscreen carries **designator *and* value**
- **mounting holes at all four corners, used with standoffs.** A 50 mm board
  cantilevered on 2.54 mm header pins bends them, and bent pins fail
  intermittently — the hardest fault to diagnose, and one this project has already
  met once on a CLKIN wire that worked loose. Let the headers carry signal and the
  standoffs carry weight.
- pin-1 and polarity markings
- do not cram: the entire purpose of this board is that it is easy to measure and
  easy to change

> If the board later grows past ~60–80 mm, replace the stack with a **short IDC
> ribbon** and stand the compute board beside the FPGA. That is not a return to the
> dupont harness that caused the original problems: an IDC ribbon is mechanically
> latched, has fixed pin order, and can interleave grounds.

### 10. Teardrops

Apply to all pads and vias — **75% width / 35% length** is appropriately
conservative. The mechanical case is real here: this board is a shield that gets
inserted and removed repeatedly, and the FPC connector is flexed by its cable.
Teardrops also remove acute-angle acid traps.

**Generate them last**, after routing is final, since any trace edit invalidates the
teardrops near it. Re-run DRC afterwards — teardrops grow copper, and the 0.5 mm
pitch VQFN-32, VSON-10 and FPC footprints are where clearance will be lost first.

---

## The divider change — highest priority, and it is a layout change

**Measured on V1:** the MRE reads **>200 MΩ at rest** (overflows the 200 MΩ range,
laterally and vertically) and about **8.6 MΩ under firm pressure**, inferred from a
~500-count reading at gain 1 against the 2.5 V reference.

100 kΩ against 8.6 MΩ is an **86× mismatch**. The resistance has to fall three orders
of magnitude before anything appears, which is why light touch produces nothing and
firm pressure jumps by hundreds of counts as percolation paths form and break.

| Divider | at rest | pressed | usable swing | source impedance |
|---|---:|---:|---:|---|
| 100 kΩ (V1) | ~1 count | ~500 | 500 | 100 kΩ ✓ |
| **1 MΩ (V3)** | 215 | 4508 | **~4300 (8.6×)** | 1 MΩ |
| 10 MΩ | 2057 | 23250 | ~21000 (42×) | 10 MΩ ✗ |

**Do not jump straight to 10 MΩ.** The ADS's 1 nA input bias across 10 MΩ is 10 mV
≈ 131 counts of temperature-dependent offset; a switched-capacitor ΔΣ input may not
settle against a 10 MΩ source; and 23250 is close enough to full scale that harder
pressure saturates. With the buffer stage fitted, this constraint disappears — which
is what the op-amp footprint is for.

Tolerance barely matters: 0.1% buys about 2 counts of fixed offset, which baseline
subtraction removes. **Temperature coefficient is what matters**, because drift is
exactly what baseline subtraction cannot follow. 1% metal film at 25–50 ppm/°C.

> This also explains the flat **+2** counts seen at rest in every recent ADS capture:
> with a 100 kΩ leg against a gigaohm sensor, +2 is the correct at-rest reading. On a
> 1 MΩ leg the same untouched sensor sits near +20. See
> [`CODE/V1/SAMPLE_RATE.md`](../../CODE/V1/SAMPLE_RATE.md).

---

## Coil

Measured from the V1 sensor-board Gerber: square spiral, **4 layers in series**,
7.5 turns per layer, 0.152 mm trace / 0.229 mm space / 0.381 mm pitch, outer
7.62 mm, inner opening 2.667 mm, 600.6 mm of conductor. Modified-Wheeler and
current-sheet agree: **L ≈ 5.17 µH** (4.87–5.84 depending on inter-layer coupling),
R_dc 1.96 Ω at 1 oz.

**That is inside the LDC1101's 1–500 µH range, so no series inductor is needed.** The
≈13× dilution documented for [V1](../V1) is a property of that board's small onboard
coil plus its 4.7 µH series part; the split architecture removes it rather than
mitigating it.

At fixed resonance `Q = 2πf·L / Rs`, and for a planar spiral `L ∝ n²·d_avg` while
`R ∝ n·d_avg/w`. So **Q ∝ n·w** — and since turns and width compete for the same
radial space, the real lever is **w/(w+s)**. V1 spends only 0.399 of its radial
budget on copper.

| | V1 | candidate |
|---|---:|---:|
| trace / gap | 0.152 / 0.229 mm | **0.230 / 0.127 mm** |
| outer diameter | 7.62 mm | 8.20 mm |
| turns per layer | 7.5 | 8.0 |
| w/(w+s) | 0.399 | **0.644** |
| R_dc | 1.86 Ω | 1.47 Ω |

Tightening the gap alone — 0.229 → 0.127 mm, standard 5 mil, costs nothing — is the
single largest contributor.

Circular beats rectangular for Q at equal area, and mutual inductance between stacked
layers raises L without raising Rs, so layer count stays the cheapest lever. For a
**contact** application the usual `d_IN/d_OUT > 0.3` guidance does not apply; ratios
down to 0.05 are fine and inner turns add sensitivity.

**Two constraints that are easy to get backwards.** `RP = L/(Rs·C)`, so `RP ∝ 1/C`:
adding tank capacitance to lower the sensor frequency collapses RP, and the device
needs RP ≥ 1.25 kΩ and Q ≥ 10. And `fCLKIN > 4·fSENSOR` is a **resolution**
guideline, not an aliasing limit — in RP+L mode the sensor gates a counter that
counts CLKIN, so a low CLKIN costs counts, not correctness. Do not distort the tank
to satisfy it; raise CLKIN instead.

### Tank capacitor

**560 pF C0G/NP0 50 V** nominal, on the sensor board beside the coil, with three
parallel positions.

Chosen against two uncertainties at once — L to ±10% (coupling estimate) and RP to
±50% (the proximity-effect coefficient is estimated). 560 pF is the only value that
stays compliant in the worst combination: 470 pF drops the CLKIN ratio to 3.97 when
L runs low, and 680 pF drops RP to 1.08 kΩ when RP runs low, under the 1.25 kΩ floor.
**RP falling out of range is the more serious failure** — the datasheet warns the
LDC1101 may then be unable to drive the sensor at all.

Stock a few each of 470 / 560 / 680 pF and settle it on the first article;
inter-layer parasitics on a stacked spiral add tens of pF to the nominal.

**Lower bound on sensor frequency:** RP falls with frequency, and at 1200 pF
(2.02 MHz) RP ≈ 1.22 kΩ is already under the floor. **Do not go below ~2.2 MHz.**

---

## The three spare pins

Each needs a passive that defines a safe state while the FPGA is still configuring —
every FPGA I/O is high-impedance until the bitstream loads.

| Signal | Passive | Safe default | If left floating |
|---|---|---|---|
| `ADS_RESET` | 10 kΩ up to IOVDD | not reset (active low) | noise pulls it low → random ADC resets |
| `LDO_EN` | 100 kΩ up to VIN | rail on | LDLN025 has no internal pull; undefined → LDO may not start or may chatter |
| `ADS_CLK` | pulldown (or DNP 0 Ω) to DGND | ADS uses its internal oscillator | datasheet requires CLK at DGND when unused |

> **`LDO_EN` and back-powering.** Pulling EN low while the FPGA still drives SPI
> pushes 3.3 V through the peripherals' ESD diodes into their unpowered VDD. The RTL
> must gate LDO EN and all peripheral I/O drive from one `periph_en`.

---

## Fixable in firmware — do not hold the order for these

| Setting | Value | Effect |
|---|---|---|
| `fCLKIN` (LDC) | **13.5 MHz** = 27 ÷ 2, plain divider, no PLL | fSENSOR ≈ 2.96 MHz, ratio 4.56 |
| `DIG_CONF` | **0xD7** (MIN_FREQ = 13 → 2.667 MHz watchdog, RESP_TIME = 6144) | current 0x07 leaves MIN_FREQ = 0 |
| `RP_SET` | bring up at **0x46** (1.5k–6k), then narrow to **0x56** (1.5k–3k) | 7.2 → 19.1 → 28.6 counts/Ω |
| `ADS_CLK` | **27 ÷ 8 = 3.375 MHz** | see below |
| `DATARATE` bit 6 | 1 = external clock | must be re-applied after every reset |
| `mux_table` | **0x5C / 0x4C / 0x3C / 0x2C** | AIN0/AIN1 became AIN2/AIN3 |

**16 MHz is unreachable** from 27 MHz: the ratio 16/27 is coprime, forcing IDIV=27
and fPFD = 1 MHz, below the Gowin rPLL's 3 MHz floor. The closest rPLL value is
15.429 MHz for only +14% more L_DATA, and it couples into the tank more easily. Use
13.5 MHz; chasing the last 14% later is a pure RTL change.

**`RP_SET = 0x46` and `DIG_CONF = 0xD7` already work at 3.375 MHz** and are
independent of the CLKIN question — measured RP ≈ 2185 Ω, comfortably centred in the
1.5k–6k window, RP resolution 7.2 → 19.1 counts/Ω. **That 2.7× is already banked.**

⚠ Do not set `RP_SET` to a narrow window before measuring. If the real RP falls
outside it, `RP_DATA` saturates and the channel is destroyed rather than improved.

⚠ **`mux_table` must not change until the V3 board is in hand** — on V1 it would read
the wrong channels. The corner mapping is unaffected: C stays CH3 and D stays CH2, so
calibration and the heat-map layout do not move.

⚠ **A reset reverts the ADS to its internal oscillator**, so the external-clock bit
has to be re-applied in every initialisation, after the reset in the sequence.

---

## Two things this session's measurements change

**1. `CLK_DIV` is not the sample-rate lever, and the note that said so was wrong.**

An earlier design note argued that restoring `CLK_DIV` from 56 to 14 was *necessary*
for TTCGS, on the grounds that the paper's reflex band needs 1 kSPS. A logic analyser
on the bus says otherwise: SPI traffic is **104 µs of a 1572 µs conversion cycle**.
Restoring `CLK_DIV = 14` recovers ~78 µs — 636 Hz becomes about 669 Hz — while giving
back the 60× noise improvement that slowing it down bought. The rate lever is `DR`.
Full budget in [`CODE/V1/SAMPLE_RATE.md`](../../CODE/V1/SAMPLE_RATE.md).

Trying `CLK_DIV = 14` again once the board has a proper ground plane is still
reasonable — just not for the reason previously given, and not as a priority.

**2. The ADS clock divider should be ÷8, not ÷7.**

`ads114s08_spi.v`'s comment proposes 27 MHz ÷ 7 = 3.857 MHz as closest to the nominal
4.096 MHz. The duty-cycle specification is 40 / 50 / 60%, and an odd divider can only
produce 42.9% / 57.1% — hard against the limit. **27 ÷ 8 = 3.375 MHz toggles every
four clocks for exactly 50%**, dead centre. ÷6 = 4.5 MHz lands on the frequency
ceiling and is out.

The data rate then scales by ×0.824 (nominal 800 → 660 SPS) — but *exactly known*,
which is the entire point, replacing the internal oscillator's ±2%. And **13.5 MHz is
exactly 4 × 3.375 MHz**, so the two peripherals stay harmonically related and cannot
beat against each other.

TTCGS defines its DoG σ in **samples**, so a drifting oscillator drags every published
passband with it. Going external turns those band edges into numbers that can be
calculated and written down.

---

## What the changes buy

Clock and register changes only, no hardware — **conditional on CLKIN routing**:

| | V1 now | V3 target |
|---|---:|---:|
| `L_DATA` | 1361 (2.1% FS) | **9347 (14.3% FS) — 6.9×** |
| RP resolution | 7.2 counts/Ω | **28.6 counts/Ω — 4.0×** |

Layout changes:

| | V1 now | V3 target |
|---|---:|---:|
| piezoresistive usable swing | ~500 counts | **~4300 counts — 8.6×** |
| ground-drop error on AIN | measured as signal | common-mode, subtracted |
| coil ΔL dilution | ≈13× | none — no series inductor |
| analog power | projected | **measured**, via the rail shunts |
| getting a probe on a signal | mirror it onto spare FPGA pins and rebuild | plug into J_DIG |

---

## A positioning question the layout should leave open

On the inductive path the MRE performs well: measured **ΔL +3.7% / ΔRP −15.5%**,
monotonic, reversible, repeatable, and cleanly separated from a fingertip (L↑, RP
−8.3%) and from aluminium foil (L↓, RP −1.8%). That is ferromagnetic particles
changing permeability — the material's native mechanism, and it does not require the
composite to conduct.

The piezoresistive path works against the material's >200 MΩ insulating nature, with
an operating point on the percolation threshold: small signals, large randomness. Two
ways forward, not mutually exclusive:

1. rescue it, with the 1 MΩ divider and the buffer stage;
2. give the piezoresistive channel a **real FSR** and let the MRE serve the LDC alone
   — each modality on the transduction mechanism that suits it, which is also the
   easier argument to defend in the manuscript.

The external-sensor header on the compute board exists so that this can be settled
with measurements rather than argument.

> One more thing the layout cannot fix, recorded so it is not mistaken for an
> electrical fault: the present pad is **one continuous sheet of MRE covering all four
> electrodes**, larger than the area they enclose. That is not four independent
> sensors — each channel measures the path resistance from a shared feed point to its
> own electrode. A true four-point centre-of-force needs either **separate pads per
> corner** or an explicitly defined common electrode.

---

## Status

Design only. No Gerber, BOM, or pick-and-place is published here yet — they will land
when the revision is frozen.
