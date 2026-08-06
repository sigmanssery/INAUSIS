# impl/ — what these reports actually are

**Read this before quoting a number out of this directory.**

## What is here

`pnr/project.rpt.txt` and the accompanying HTML were produced on **2026-08-01**
from a **`top_dual` bring-up build**, not from `ttcgs_board`:

```
Physical Constraints : dual_bringup.cst
Timing Constraints   : bringup.sdc
Logic                : 1000/8640  (12%)
Register             :  633/6693  (10%)
```

`top_dual` is the two-converter readout used to take the captures in `DATA/`.
It does **not** contain the TTCGS datapath, so its resource figures have nothing
to do with the ones quoted in the papers.

`gwsynthesis/` is a synthesis run of the TTCGS datapath and is the older and
more relevant of the two, but it is a *synthesis fit*, not a place-and-route
result.

## What is NOT here

The headline post-route figures — **3334 logic cells, 2107 registers, 5 BSRAM,
4 DSP, Fmax 45.6 MHz, zero violations** — are **not reproduced by any report in
this repository.** They came from a `ttcgs_board` place-and-route run whose
output directory was overwritten by later bring-up builds, because Gowin writes
every target into the same `impl/` path.

They are not disputed and they are not withdrawn; they are simply unevidenced
here until the run is repeated. Do not cite this directory as their source.

## To restore the evidence

```sh
cd ../../04_constraints
gw_sh board_pnr.tcl          # ttcgs_board against inausis.cst + board.sdc
```

Then copy `impl/pnr/` back here **before running anything else**, and check that
the report's `<Physical Constraints File>` says `inausis.cst`. If it says
`dual_bringup.cst`, a bring-up build has overwritten it again.

## The underlying trap

Gowin writes all targets to one `impl/` directory. Synthesising a different top
silently destroys the previous target's reports. This has now cost the project
its post-route evidence twice. Either archive `impl/` immediately after any run
whose numbers will be quoted, or build each target in its own working directory.
