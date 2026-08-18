# Roadmap — deliberately deferred

Things that have been thought through and **decided against for now**. Each entry
says what it is, why it is not being done yet, and **what would have to become true
for it to be worth doing**.

Nothing here is a wish list. If an item has no trigger condition, it does not belong
on this page — it belongs in a notebook.

---

## Closing the loop: an MCU on the far end of the Manchester link

**What.** A microcontroller that receives the TTCGS frames, checks the CRC, and
writes thresholds back over the reverse channel.

**Why it matters.** It closes a real gap in the status table. The bidirectional
datapath is **R** — RTL complete and 12/12 in simulation — but it has never been
exercised on hardware, because the downstream half does not exist. Both manuscripts
describe a CRC-protected reverse channel that lets the consumer rewrite thresholds,
and the `+274 logic cells (+10.6%)` figure is offered as evidence that closing the
inference-to-sensing loop is nearly free. **That loop has never actually been
closed.** An MCU on the other end takes the bidirectional datapath from **R** to
**V**.

**Why not now.** Not because it is ambitious — because it forces a choice that
cannot yet be made well.

- Putting a bare ESP32 or STM32 on the board means also owning its crystal,
  decoupling, strapping pins, programming interface, USB and power sequencing. That
  is a second bring-up project on top of one that is not finished.
- Leaving female headers for a *module* is no better: ESP32-DevKitC, Pico and Nucleo
  have completely different footprints, so reserving pads still means picking one
  now, before any of them has been tried.

**The cheap enabler, which costs nothing.** Bring the Manchester signal out to a
four-pin header — `line` · `3V3` · `GND` · `reset`. Any MCU dev board connects with
four jumper wires. No footprint decision, no board area, no commitment.

This is not new scope: `line` is pin 42, on the left header, which the compute board
covers. [PCB/V3](PCB/V3) §1 already requires covered signals to be re-exposed.

**Trigger.** Try two or three MCUs on jumper wires first — that is the only way to
learn which one fits. Design an MCU into a **V4** once the closed-loop demonstration
is going to be a figure in a manuscript, and not before.

---

## Stacking compute boards to read several sensor boards

**What.** Several compute boards on one FPGA, each serving its own sensor board,
sharing one SPI bus.

**Why not now.** Neither manuscript needs it. The open figures — R(P), L(P), RP(P),
cyclic drift, DoG waveforms — all need **one** good measurement chain, not four.

**What it would take**, worked out so the estimate is not made from scratch later:

- **Four chip selects for the LDC.** The ADS already has a 2×4 selector; the LDC's
  `CSB` is a single line, so four stacked boards would select every LDC at once and
  their outputs would collide. The cheap answer is a **74HC138**: three FPGA pins
  become eight selects, which is exactly 4 boards × 2 chips. CS changes once per
  transaction, so the decoder's propagation delay is irrelevant at 482 kHz.
- **DRDY must become timed polling.** The dedicated DRDY pin is driven regardless of
  CS, so four boards would contend on one net. The 470 Ω series resistors keep that
  at ~3.3 mA — survivable, not usable. Polling is well founded: the conversion period
  measures **1572.2 µs with sd 0.4 µs** over 1591 conversions, so a timer tracks it
  comfortably. This is a pure RTL change and it removes the pin entirely.
- **`ldc_clkin` tri-state**, if the external clock module is also fitted.

**Trigger.** When a multi-taxel array becomes a figure in a manuscript. The pin
budget is not the obstacle it first appears — 3 pins, not 8 — but nothing above is
worth doing before there is something to put in the array.

## A custom two-layer FPC with a ground plane

**What.** Replace the off-the-shelf FFC with a two-layer flex, one layer a solid
ground plane.

**Why it matters.** The cable carries the 2.96 MHz coil pair alongside four AIN nodes
at 1 MΩ source impedance. The design notes already identify that as the largest
aggressor–victim pair in the system. Two edge conductors on a flat cable do not
shield anything — they cannot cover the broad faces — so the present design brackets
the coil pair with grounds and accepts the rest. A real ground plane under the AIN
group would give those high-impedance nodes the adjacent low-impedance reference
they currently lack.

**Why not now.** The stock FFC with the agreed pinout is expected to work, and it
has zero lead time. Custom flex costs about what a rigid prototype run costs, but
adds a fabrication cycle.

**Trigger.** If crosstalk between AIN channels, or from the coil into the AIN group,
shows up in measured data once the analog front end is producing signal.

---

## Moving the buffer to the sensor board

**What.** Put the quad op-amp on the sensor board, right after the dividers, instead
of on the compute board.

**Why it matters.** Electrically this is the better place, and the reason is the same
as above: with the buffer at the sensor, the FPC carries low-impedance signals and
the crosstalk problem largely disappears at its source rather than being mitigated
downstream.

**Why not now.** It does not fit. The sensor board is 20 × 20 mm with a 12.2 mm
ground keep-out, leaving a ring under 4 mm wide; a SOIC-14 is 3.9 mm across before
its decoupling. And 20 × 20 mm is a hard limit set by the gripper.

**This is a known unresolved point, not a solved one.** The current placement accepts
the FPC crosstalk rather than fixing it.

**Trigger.** If the crosstalk above proves real. Acting on it means reopening the
20 × 20 mm constraint, which is a mechanical conversation, not an electrical one.

---

## A better coil: circular, more layers

**What.** Circular spiral instead of square, and more stacked layers.

**Why it matters.** SNOA930 §2.1: a circular spiral gives the best Q and lowest Rs
for a given area. Mutual inductance between stacked layers raises L **without**
raising Rs, which makes layer count the cheapest lever on Q available. The square
geometry in V1 was a footprint compromise, not an optimisation.

**Why not now.** [PCB/V3](PCB/V3) already takes the largest single improvement
available — tightening trace/gap from 0.152/0.229 mm to 0.230/0.127 mm, which moves
`w/(w+s)` from 0.399 to 0.644 and costs nothing, since 5 mil is standard. Q ≈ 27 is
comfortably inside the LDC1101's 10–400 requirement. There is no measured deficiency
to fix.

**Trigger.** If the coil-level ΔL turns out to sit below the resolution bound — the
principal open risk in [MRE/V1](MRE/V1), estimated at 0.02–0.12% against a ≈0.13%
requirement. Raising coil self-inductance is one of the two recovery levers; the
other is material.

---

## Separate sensing pads per corner

**What.** Four independent elastomer pads instead of one continuous sheet.

**Why it matters.** The present pad is a single sheet covering all four electrodes
and larger than the area they enclose. **That is not four independent sensors** —
each channel measures the path resistance from a shared feed point to its own
electrode, so the four readings are not separable in the way a centre-of-force
calculation assumes.

**Why not now.** The current arrangement is sufficient for detecting and localising
contact, which is what the captures in [DATA](DATA) demonstrate.

**Trigger.** If a genuine four-point centre-of-force measurement is claimed. The
alternative fix is to define the common electrode's position explicitly, which may
be cheaper than four pads.

---

## fCLKIN at 15.429 MHz

**What.** Use the Gowin rPLL to reach 15.429 MHz instead of the plain 27 ÷ 2 =
13.5 MHz divider.

**Why it matters.** About +14% more `L_DATA` resolution.

**Why not now.** 16 MHz is unreachable — the ratio 16/27 is coprime, forcing IDIV=27
and fPFD = 1 MHz, below the rPLL's 3 MHz floor. 15.429 MHz is the closest available
and buys only 14%, while coupling into the tank more easily than 13.5 MHz does. And
13.5 MHz itself is not yet proven: it killed the tank on the dupont prototype, and
whether the V3 routing fixes that is the open question the board exists to answer.

**Trigger.** After 13.5 MHz is confirmed working on real hardware. It is a pure RTL
change at that point.

---

## The sample rate decision — CLOSED 2026-08-18

**Kept here because the reasoning below was wrong in an instructive way.**

The entry used to say the hardware ran at 159 SPS against the manuscripts' 1 kSPS,
and that the way out was to raise `DR`, re-derive the numbers, or parameterise σ.
All three assumed the converter was the bottleneck. It was not.

The factor of six was the four-channel round-robin and a 10 ms UART emitter
period. Removing both gives **689 SPS on one channel**, where the RTL's σ = 2/8/85
samples land at 2.9/11.6/123 ms against the papers' 2/8/85 ms — within 40%, with
no kernel change and no `DATARATE` change. See
[SAMPLE_RATE.md](CODE/V1/SAMPLE_RATE.md).

**What remains open is narrower and should be written as a limitation:** the 2 ms
reflex band is 1.4 samples at 689 SPS and about 3 samples even at `DR = 0x3D`. It
is not validated by this hardware and should not be claimed as such.

**The lesson worth keeping:** the trigger condition on this entry was "after V3
produces real signal", which framed it as a hardware problem. Two firmware
constants fixed it. Check what is actually spending the budget before designing
around a limit.

---

## Restoring `CLK_DIV = 14`

**What.** Return the ADS SPI clock from 482 kHz to 1.93 MHz.

**Why it matters.** Less, as it turns out, than was previously believed. SPI traffic
is 104 µs of a 1572 µs conversion cycle, so restoring it moves 636 Hz to about
669 Hz — while giving back the 60× noise improvement that slowing it down bought.
The earlier claim that this was *necessary* for TTCGS has been withdrawn.

**Trigger.** Once the board has a proper ground plane, try it and measure the bad-read
rate. Low priority, and not for the reason originally given.

---

## Re-capturing the SPI bus at 24 MHz

**What.** Repeat the logic-analyser capture in [DATA](DATA) at the analyser's full
24 MHz instead of 4 MHz.

**Why it matters.** 4 MHz is only ~8 samples per SCLK period. CS edges and clock
edges land on the same sample often enough to shift byte framing by one bit, which
made the decode ambiguous until it was cross-checked against the RTL's `total_bits`.

**Why not now.** The question that capture was taken to answer is answered.

**Trigger.** The next time the SPI bus needs looking at.

---

## A note on how this list is meant to work

Several of these are triggered by the same event — **measured data from a working
analog front end**. That is not a coincidence. It is the bottleneck, and it is why
the current revision spends its effort on making the front end measurable rather
than on making it more capable.

The instinct to build the complete, modular, once-and-for-all version is the same
instinct that produced the sensor/compute split, the FPC boundary, the
populate-or-bypass buffer, and the swappable divider and tank values. Those are all
good decisions and they all came from it.

What modularity actually buys is not a board that never needs revising — hardware
does not work that way, and this project is on its third revision already. It is
that **the next revision gets cheap**. Changing a divider value on X004 meant a new
board; on the evaluation board it means changing one 0805. Same decision, two weeks
versus two minutes.

That return compounds. This page exists so the ideas earning it do not get lost, and
do not quietly become this revision's scope.
