# MRE / V1 — chain-aligned magnetorheological elastomer

The sensing material. Carbonyl nickel powder dispersed in a silicone matrix and
cured under a DC magnetic field, which assembles the particles into chains along
the field direction. One material, two orthogonal readouts.

> **Fabrication:** see [PROCESS.md](PROCESS.md) for the full recipe, process steps,
> and per-batch verification — **including the safety section, which should be read
> before handling the filler.** Carbonyl nickel at 1–3 µm is respirable and nickel
> is a sensitizer and an inhalation carcinogen.

## Formulation

| | |
|---|---|
| Filler | carbonyl nickel, 1–3 µm, **70 wt% ≈ 22 vol%** |
| Matrix | Sylgard 186, plasticized with dimethyl silicone oil (5–15 wt% of matrix) |
| Coupling agent | vinyltrimethoxysilane (A-171) |
| Curing field | **~0.9 T** DC |
| Thickness | 1.5 mm |
| Composite modulus | ≈1.2–1.6 MPa (Guth–Gold from the 0.5–1 MPa base at φ ≈ 0.22, partly offset by the plasticizer) |

## Why these substitutions

The recipe is adapted from Liao et al. (2017), who characterized chain-aligned MREs
at 70 wt% carbonyl nickel in an RTV-2 condensation-cure silicone with KH550
amine-silane treatment, chained at 300–500 mT. Three changes adapt it to this
platform, and each is a consequence rather than a preference:

- **Matrix → Sylgard 186 (addition cure).** Condensation byproducts boil under
  vacuum, which rules out degassing in a sealed mold; addition cure is byproduct-free
  and its near-zero shrinkage preserves the mold's thickness reference.
- **KH550 → A-171.** KH550 is an amine silane and therefore a platinum-cure
  inhibitor. A-171 is not only addition-cure compatible, it participates in
  hydrosilylation and covalently bonds the particle surface into the network.
- **500 mT → ~0.9 T.** Nickel saturates near 0.2 T, so the inter-particle chaining
  force is unchanged; the higher field adds only chain-straightening torque. SEM
  series data show the chain-length fraction still rising toward 1000 mT
  (Σk/L: 0.55 at 400 mT, 0.60 at 600 mT, 0.71 at 1000 mT). The lateral-agglomeration
  risk reported at high fields in low-viscosity matrices is suppressed here by the
  ~200 Pa·s paste viscosity and a thermally shortened gel time, and is checked
  post-cure by lateral-resistance inspection.

Field-cured chaining is a **necessary condition**, not an optimization: zero-field
samples start near 10¹² Ω and need 14–24 kPa before their resistance moves at all.

## The two readouts

**Below ~6 kPa — piezoresistive.** Compression narrows the nanometre-scale silicone
gaps between adjacent particles in a chain; field-emission conduction across those
barriers rises exponentially and the resistance falls by ~5 orders of magnitude.
Read as a simple divider against a fixed 100 kΩ 1% resistor.

**Above ~6 kPa — inductive.** The chains have collapsed into near-metallic contact,
dR/dP → 0, and the piezoresistive channel is information-saturated. The same
compression is then read through the effective permeability the chains present to
the PCB planar coil. Predicted signature: **ΔL > 0** under compression — the
response of a permeability-coupled target, opposite in sign to the ΔL < 0 of a
conventional conductive target.

**The crossover is not a design parameter.** It is the pressure at which the
piezoresistive sensitivity vanishes.

## One state variable, two couplings

Within the Wiener series bound, the axial permeability of a chained composite is
limited by its lowest-permeability segments — precisely the inter-particle silicone
gaps whose width sets the field-emission resistance. Compression narrows the same
nanometre-scale gaps that raise conduction exponentially and, through the series
bound, raise μ∥.

The two modalities therefore read **one microstructural quantity — gap width —
through two orthogonal physical couplings**. That is the physical basis of the
dual-modal pairing rather than a coincidence of co-location.

## What is negligible, and why that matters

Two mechanisms a conductive bulk target would contribute are negligible here **by
construction**:

- **Eddy-current loss.** Macroscopic eddy currents need laterally closed conduction
  loops, but the chains are mutually insulated by the matrix. At 4.6 MHz a single
  inter-particle gap presents 1–10 MΩ of capacitive impedance, and intra-particle
  loss scales as a⁵ for a = 0.5–1.5 µm. Structurally the cured composite is the
  particulate analog of a powdered magnetic core — a geometry engineered to keep
  permeability while excluding eddy currents.
- **Villari (inverse-magnetostrictive) coupling.** The magnetoelastic energy density
  is ≈0.3 J/m³ at the 6 kPa crossover and ≈17 J/m³ at 335 kPa, below 1% of nickel's
  magnetocrystalline anisotropy (|K₁| ≈ 5×10³ J/m³) across the whole range.

This is a load-bearing negative result: it removes the converter's RP output from
the pressure path and reassigns it as a dedicated **external-conductor** channel.
The readout is also passive — the tank's µT-scale excitation is five to six orders
of magnitude below the ~0.2 T at which magnetostrictive deformation becomes
measurable, so the coil cannot actuate the elastomer it is reading.

## Status — this is the open gate

The formulation and process are **fixed**. The physical analysis of both channels is
**complete**, including a sensitivity budget. What is **not** done is the
characterization of the fabricated skin:

- [ ] **R(P)** — piezoresistive curve vs. model fit, ≥3 samples
- [ ] **L(P) and RP(P)** — inductive curves under controlled compression
- [ ] **cyclic drift** — R and L baselines vs. cycle count, from the ninth cycle
      after Mullins break-in

No measured curve of the present formulation is claimed anywhere in this
repository or in the manuscripts.

### The principal open risk, stated plainly

The bare PCB coil contributes only 0.4 µH of the 5.1 µH tank, so any coil-level
inductance change is diluted **≈13×** at the point where the converter measures.
Clearing the ±0.01% resolution floor therefore needs a coil-level ΔL/L of at least
**≈0.13%**. A first-order estimate combining the mixing superlinearity and the
field-gradient term places the response to the ~6–8 µm compression at the crossover
in the **0.02–0.12%** range — predominantly *below* that bound.

If that holds, the two channels are separated by a narrow blind band rather than
overlapping. Two classes of recovery lever exist:

- **electrical** — the dilution is a layout quantity, not a physical limit: raising
  the coil's self-inductance and shrinking the series inductor recovers sensitivity
  proportionally;
- **material** — plasticizer content and fill fraction both lower the composite
  modulus, increasing the strain available at the crossover.

Resolving this is the first thing the fabricated skin is for.
