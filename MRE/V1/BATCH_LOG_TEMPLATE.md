# MRE batch log — fill at the bench

Copy this file to `MRE/V1/batches/<YYYY-MM-DD>_batch<N>.md` and fill it **while
the batch is running**, not afterwards. Every field here is one that
[PROCESS.md](PROCESS.md) currently marks `[TO FILL]`, plus a few that only exist
at the moment of making.

Each section names the PROCESS.md section it folds back into, so transferring a
completed log is mechanical.

**Record what actually happened, including deviations.** A log that reads exactly
like the intended recipe is a log that was written from memory. If a step went
wrong, that is the most valuable line on the page — the previous batch cracked and
nobody wrote down why.

---

```
Batch ID        ____________________
Date            ____________________
Operator        ____________________
Ambient         ______ °C     ______ %RH
```

**Safety check before opening the nickel** — fume hood or glove box ready, FFP3
fitted, nitrile gloves on, damp cloth for spills, magnet working volume cleared of
tools/phones/cards. → `[ ]`

---

## A. Weigh-in → PROCESS.md *Materials*

Record **actual weighed mass**, not the recipe ratio. The ratio is already in
PROCESS.md; what is missing is what went into this batch.

| Component | Target | Actual mass | Notes |
|---|---|---|---|
| Carbonyl nickel, 1–3 µm | 70 wt% of total | ______ g | lot / supplier: __________ |
| Sylgard 186 part A | | ______ g | |
| Sylgard 186 part B | | ______ g | |
| Dimethyl silicone oil | 5–15 wt% of matrix | ______ g | actual wt% of matrix: ______ |
| A-171 (vinyltrimethoxysilane) | — | ______ g | **wt% of filler: ______** ← PROCESS.md *Materials* |
| **Batch total** | | ______ g | |

### Why the previous batch failed

Write this **before** starting, while it is still fresh. Thickness variation?
Tearing on demold? Too brittle at this filler loading? Edge crack from the mold?

```
____________________________________________________________________
____________________________________________________________________
```

---

## B. Filler surface treatment → PROCESS.md §1

| Field | Value |
|---|---|
| A-171 loading | ______ wt% of filler |
| Solvent | ____________ , ______ mL |
| Mixing time | ______ min |
| Drying temperature | ______ °C |
| Drying time | ______ h |

```
Deviations / observations:
____________________________________________________________________
```

---

## C. Mixing → PROCESS.md §2

**Order of addition**, with the interval between steps:

```
t = 0:00   ____________________________________________________
t = ____   ____________________________________________________
t = ____   ____________________________________________________
t = ____   ____________________________________________________
t = ____   ____________________________________________________
```

| Field | Value |
|---|---|
| Mixer type | planetary / paddle / hand — ____________ |
| Speed | ______ rpm |
| Total duration | ______ min |
| Temperature | ______ °C |

**Viscosity.** The target is ~200 Pa·s, and it is load-bearing — it is what
suppresses lateral agglomeration during field cure. If there is no rheometer,
record a repeatable proxy rather than leaving this blank:

```
Subjective description (e.g. "holds a peak", "levels in ~N s"):
____________________________________________________________________
Time for the surface to level after stirring stops:  ______ s
Pot life observed before it became unworkable:       ______ min
```

---

## D. Degassing → PROCESS.md §3

| Field | Value |
|---|---|
| Vacuum level | ______ mbar (or ______ inHg) |
| Duration | ______ min |
| Break-vacuum cycles | ______ |

```
Did it stop bubbling, or did you stop it?  ____________________________
```

---

## E. Mold and thickness → PROCESS.md §4

| Field | Value |
|---|---|
| Mold material | ____________________ |
| Thickness reference method | shims / machined cavity / spacer — ____________ |
| Reference value used | ______ mm (target 1.5 mm) |

**Measured finished thickness** — this field is not yet in PROCESS.md and must be
added. Without it no L(P) curve can be compared against anyone else's.

```
Measure at 5 points with a micrometer, after post-cure:

  ______  ______  ______  ______  ______  mm
  mean ______ mm      spread ______ mm
```

---

## F. Field cure → PROCESS.md §5

This is the section the whole inductive argument rests on.

| Field | Value |
|---|---|
| Field source | permanent magnet pair / electromagnet — ____________ |
| Model / dimensions / gap | ____________________ |
| Gaussmeter model | ____________________ |
| **Where the field was measured** | air gap centre / sample surface / other — ____________ |
| Measured field at that point | ______ T |
| Cure temperature | ______ °C |
| Cure duration | ______ min |
| Gel time | ______ min, from t = ______ (which step?) |

> **The measurement position decides whether "~0.9 T" is true.** Air-gap centre and
> sample position can differ substantially. State the position; a field value
> without one is not usable by anyone reproducing this.

**Orientation check.** Chains must align along the coil axis, i.e. perpendicular to
the layer. Record how you confirmed the sample was not placed rotated:

```
____________________________________________________________________
```

---

## G. Demold and post-cure → PROCESS.md §6

| Field | Value |
|---|---|
| Release agent | none / ____________ |
| Demold method | ____________________ |
| Post-cure temperature | ______ °C |
| Post-cure duration | ______ h |

> A release agent that transfers to the surface will contaminate the electrode
> contact and show up later as an unexplained series resistance. If one was used,
> record how the surface was cleaned.

```
Damage on demold (tears, edge cracks, thickness loss):
____________________________________________________________________
```

---

## H. Verification → PROCESS.md *Verification*

Run on **every** batch.

### H1. Lateral resistance — not optional

Measured **across** the sheet, perpendicular to the chain direction, unloaded.
This is the check that the high-field cure did not cause lateral agglomeration. A
low value means the chains bridged sideways and **the batch is unusable for the
inductive channel**, because the eddy-current argument requires no laterally closed
conduction loops.

| Field | Value |
|---|---|
| Measurement voltage | ______ V |
| Electrode geometry | ____________________ (spacing ______ mm, contact area ______ mm²) |
| Pass threshold used | > ______ Ω |
| **Measured** | ______ Ω |
| **Verdict** | pass / **fail — do not use for inductive work** |

### H2. Through-thickness resistance, unloaded

Liao et al. report ~1 MΩ for chained samples. Field-emission conduction is
**voltage dependent**, so a value taken on an insulation tester at a fixed test
voltage will not match one taken under the divider's ≤3.3 V bias. Compare like
with like, and always record the bias.

| Field | Value |
|---|---|
| Bias used | ______ V |
| Instrument | ____________________ |
| **Measured** | ______ Ω |

If measured through the INAUSIS chain rather than a meter, convert with the
calibrated form in [DATA/README.md](../../DATA/README.md):

```
R = 100 kΩ × (32767 / counts − 1)          counts = ______  →  R = ______ Ω
```

### H3. SEM — for the Σk/L chain-length fraction

| Field | Value |
|---|---|
| Sample preparation | cross-section / fracture — ____________ |
| Magnification | ______ × |
| How Σk/L was scored | ____________________ |
| **Σk/L** | ______ |

> If no SEM access, write **"not performed"** rather than leaving it blank. A
> stated gap is honest; a blank reads as an oversight, and the permeability
> estimate depends on this number.

### H4. Break-in before any characterization

Elastomers show the Mullins effect over the first loading cycles. Take
representative curves from the **ninth cycle** after break-in, not the first.

```
Break-in cycles run  ______      Load used  ______ N      Date  __________
```

---

## Fold-back checklist

When the batch is complete, transfer into [PROCESS.md](PROCESS.md) and tick:

```
[ ] Materials — A-171 wt% of filler
[ ] §1 Surface treatment — loading, solvent, mixing time, drying temp/time
[ ] §2 Mixing — order of addition, mixer, speed, duration, temperature
[ ] §3 Degassing — vacuum level, duration, break-vacuum cycles
[ ] §4 Mold — material, thickness reference method
[ ] §4 Mold — ADD a measured-finished-thickness row (not currently present)
[ ] §5 Field cure — source, measurement (incl. position), temp, duration, gel time
[ ] §6 Demold and post-cure
[ ] Verification — lateral: voltage, geometry, threshold
[ ] Verification — through-thickness: value and bias
[ ] Verification — SEM: preparation, magnification, scoring
```

Keep the filled log in `MRE/V1/batches/`. PROCESS.md carries the recipe; the logs
carry what was actually done, and the difference between them over several batches
is the only record of what the process is sensitive to.
