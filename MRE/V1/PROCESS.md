# MRE / V1 — fabrication process

Everything needed to reproduce the sensing skin. Sections marked **`[TO FILL]`**
are process parameters that only the author's own runs can supply — they are left
blank rather than guessed, because a plausible-looking number that nobody actually
used is worse than an honest gap.

> **Making a batch? Use [BATCH_LOG_TEMPLATE.md](BATCH_LOG_TEMPLATE.md).** It lists
> every gap below as a fill-in field, in the order the bench work happens, and maps
> each one back to the section it belongs in. Most of these can only be recorded
> while the batch is running — afterwards they are gone.

---

## ⚠ Safety — read before handling the filler

**Carbonyl nickel powder (1–3 µm) is a respiratory hazard and a skin sensitizer.
Nickel compounds are classified as carcinogenic by inhalation.** A 1–3 µm powder is
respirable: it reaches the deep lung.

Minimum precautions:

- Weigh and transfer the powder in a **fume hood or a glove box**, never on an open
  bench. Do not use compressed air to clean up.
- **P100 / FFP3 respirator** if any handling occurs outside containment.
- **Nitrile gloves**, changed after powder handling; nickel is a common contact
  allergen and sensitization is permanent.
- Wipe spills with a **damp** cloth; sweeping or vacuuming with a domestic vacuum
  aerosolizes the powder.
- Uncured silicone with nickel filler is waste with a metal-powder component —
  dispose per local regulations, not down a drain.

The curing step also involves a **~0.9 T permanent magnet or electromagnet
assembly**. Fields at this level will destroy magnetic storage media and pacemakers,
and will accelerate loose ferromagnetic objects. Keep tools, phones, and cards
clear of the working volume.

---

## Materials

| Component | Specification | Role |
|---|---|---|
| Carbonyl nickel powder | 1–3 µm, **70 wt%** of the total (≈ **22 vol%**) | conductive and magnetic filler |
| Sylgard 186 | two-part, addition cure | matrix |
| Dimethyl silicone oil | **5–15 wt% of the matrix** | plasticizer / modulus adjustment |
| Vinyltrimethoxysilane (A-171) | `[TO FILL]` wt% of filler | particle surface treatment |

Volume fraction is computed with ρ_Ni = 8.9 g·cm⁻³ and a plasticized-matrix density
of ≈1.10 g·cm⁻³ (from the manufacturer's cured specific gravity of 1.12 and the
10 wt% oil fraction). The plasticizer shifts the filler volume fraction by less than
half a percentage point, so ≈22 vol% applies to oil-free mechanism-verification
samples as well.

### Why these, and not the source recipe's

The formulation is adapted from Liao et al. (2017). Three substitutions, each a
consequence rather than a preference:

| Changed | From | To | Because |
|---|---|---|---|
| Matrix | RTV-2 condensation cure | **Sylgard 186** (addition cure) | condensation byproducts boil under vacuum, which rules out degassing in a sealed mold; addition cure is byproduct-free and its near-zero shrinkage preserves the mold's thickness reference |
| Coupling agent | KH550 (amine silane) | **A-171** (vinyl silane) | KH550 is a platinum-cure inhibitor; A-171 is addition-cure compatible *and* participates in hydrosilylation, bonding the particle surface into the network |
| Curing field | 300–500 mT | **~0.9 T** | nickel saturates near 0.2 T so the chaining force is unchanged; the extra field contributes chain-straightening torque. SEM series show chain-length fraction still rising toward 1000 mT (Σk/L: 0.55 @ 400 mT, 0.60 @ 600 mT, 0.71 @ 1000 mT) |

The lateral-agglomeration risk reported at high field in low-viscosity matrices is
suppressed here by the ~200 Pa·s paste viscosity and a thermally shortened gel time
— and is **checked post-cure**, not assumed (see Verification).

---

## Process

### 1. Surface treatment of the filler

```
[TO FILL]  A-171 loading, solvent, mixing time, drying temperature and time
```

### 2. Mixing

```
[TO FILL]  order of addition, mixer type, speed, duration, temperature
```

Target: a paste of roughly **200 Pa·s**. This viscosity is load-bearing — it is
what suppresses lateral agglomeration during field cure.

### 3. Degassing

```
[TO FILL]  vacuum level, duration, number of break-vacuum cycles
```

Sealed mold, vacuum degassing. This is why the matrix had to be addition-cure.

### 4. Mold and thickness reference

| | |
|---|---|
| Target thickness | **1.5 mm** |
| Mold material | `[TO FILL]` |
| Thickness reference method | `[TO FILL]` (shims / machined cavity / spacer) |
| **Measured finished thickness** | `[TO FILL]` — mean and spread over 5 points, after post-cure |

The measured thickness is not a formality. Both channels scale with it, so an
L(P) or R(P) curve cannot be compared against another laboratory's without it.

### 5. Field cure

| | |
|---|---|
| Field strength | **~0.9 T** |
| Field source | `[TO FILL]` (permanent magnet pair / electromagnet) |
| Field measurement | `[TO FILL]` (gaussmeter model, where measured) |
| Field orientation | perpendicular to the layer, i.e. along the coil axis |
| Cure temperature | `[TO FILL]` |
| Cure duration | `[TO FILL]` |
| Gel time | `[TO FILL]` — thermally shortened relative to room-temperature cure |

The chains must align **along the coil axis**; that alignment is what reduces the
demagnetizing penalty and gives the axial permeability the inductive channel reads.

### 6. Demold and post-cure

```
[TO FILL]
```

---

## Verification

Run these on every batch. The first is not optional — it is the check that the
high-field cure did not do the thing high-field cure is known to do.

### Lateral resistance

Measure resistance **across** the sheet (perpendicular to the chain direction),
unloaded.

- **Expected: very high**, consistent with mutually insulated chains.
- **A low lateral resistance means lateral agglomeration** — the chains have bridged
  sideways. That batch is unusable for the inductive channel, because the whole
  eddy-current argument depends on there being no laterally closed conduction loops.

```
[TO FILL]  measurement voltage, electrode geometry, pass/fail threshold
```

### Through-thickness resistance, unloaded

- Liao et al. report ~1 MΩ unloaded for their chained samples.
- Note that field-emission conduction is **voltage dependent**, so absolute
  resistance under the divider's ≤3.3 V bias will sit higher than values taken on an
  insulation-resistance meter at a fixed test voltage. Compare like with like.

```
[TO FILL]  measured value and the bias used
```

### SEM

For the chain-length fraction Σk/L used in the permeability estimate.

```
[TO FILL]  sample preparation (cross-section / fracture), magnification, how Σk/L was scored
```

### Break-in before any characterization

Elastomers show the **Mullins effect** over the first loading cycles. Follow the
established stress-softening protocol: take representative curves from the
**ninth cycle** after break-in, not the first.

---

## What is established, and what is not

**Established:** the formulation, the substitution rationale, and the physical
analysis of both channels — including the sensitivity budget and its principal
open risk (see [README.md](README.md)).

**Not established:** any measured curve of this formulation. R(P), L(P), RP(P), and
cyclic drift are all pending, and no such curve is claimed anywhere in this
repository or in the companion manuscripts. The expectation from the substituted
matrix is a curve **shifted** from Liao et al. — a stiffer matrix yields less strain
at equal pressure — while preserving monotonicity and the order-of-magnitude swing.
Per the encode-not-decide principle, the exact curve is absorbed by downstream
calibration; what must hold is monotonicity, not linearity.
