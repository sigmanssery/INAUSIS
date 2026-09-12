# impl/ — what these reports actually are

**Read this before quoting a number out of this directory.**

Everything here is a single coherent `ttcgs_board` run from **2026-09-09**,
`BUILD_ID 0x0935`. It is the build every recording in the filter manuscript was
taken through, which is why it is the one kept here rather than the newest one.

## The run

| | |
|---|---|
| Top module | `ttcgs_board` |
| BUILD_ID | **0x0935** (frame dim 4; see `dsp_chain.v`) |
| Device | GW1NR-LV9QN88PC6/I5 (GW1NR-9, version C) |
| Physical constraints | `inausis.cst` |
| Timing constraints | `board.sdc` |
| Tool | GowinSynthesis + Gowin PnR, V1.9.11.03 Education |
| Date | 2026-09-09 22:45:49 |
| Errors / warnings | none |

Two checks before quoting. `project.rpt.txt`'s `<Physical Constraints File>`
must say `inausis.cst` — if it says `dual_bringup.cst`, a bring-up build has
overwritten this directory again (see the trap at the bottom). And the board a
recording came from must report `BUILD_ID 0x0935` in dim 4, because nothing else
distinguishes a frame produced by this build from one produced by another.

## Post-route results

```
Logic       6716/8640  (78%)     5744 LUT/ALU/ROM16  (4850 LUT, 894 ALU) + 162 SSRAM
Register    3730/6693  (56%)
BSRAM          6/26    (24%)     5 SDPB + 1 pROM
DSP            5/10    (50%)

clk27       constraint 27.000 MHz     actual Fmax 27.049 MHz     logic level 19
            12,998 paths analysed, 0 setup violated, 0 hold violated

Power       38.290 mW total  =  26.427 quiescent + 11.863 dynamic
```

Gowin's `Logic` column counts `LUT + ALU + ROM16 + 6 × RAM16`: `5744 + 6×162 =
6716`.

The DoG pipeline alone — one circular buffer, one time-multiplexed MAC engine
and the coefficient ROM, instance `u_dog` in `gwsynthesis/project_syn_resource.html`
— is **316 LUT + 100 ALU = 416 logic cells, 341 registers, 1 DSP, 3 BSRAM**.

### The margin is thin, and that is a standing constraint

**Fmax 27.049 against a 27.000 MHz constraint is 0.2% of margin.** Adding
observability to this design is not free: on 2026-09-12 putting two spare status
bits on the flag engine's outputs dropped it to 26.488 MHz with 11 setup
violations, and the failing paths were all inside `zscore_flag_multi`'s
square-to-threshold chain rather than on the added net — at 92% CLS occupancy a
little more logic re-places that chain into a violation. Those paths decide the
detection thresholds, so a build that misses there is not usable. Give
`zscore_flag_multi` timing headroom before adding taps.

Gowin's PnR is deterministic for a given input: the same sources rebuilt twice
give identical Fmax. Variation between builds is caused by the sources changing,
not by the tool.

## The reverse-channel cost — STALE, do not quote

The `+274 logic cells (+10.6%)` figure for closing the inference-to-sensing loop
came from `ttcgs_top` / `ttcgs_sys` synthesis runs of **2026-08-08**, archived at
`gowin_syn/impl_archive/2026-08-08_ttcgs_{top,sys}_syn/`. `dsp_chain.v` and
`zscore_flag_multi.v` have both grown substantially since, so that difference no
longer describes the current RTL. Re-run both tops if the number is needed.

## `gwsynthesis/`

Synthesis-stage output for the same `ttcgs_board` run. It is a *synthesis fit*,
not a place-and-route result — where the two disagree, `pnr/` is authoritative.
Its `project_syn_resource.html` is the only place the per-instance breakdown
(`u_dog`, `u_flag`, `u_slide`, …) appears.

## To repeat the run

```sh
cd CODE/V1/02_rtl_production      # or gowin_syn/ in the working package
gw_sh board_pnr.tcl
```

`board_pnr.tcl` lists every source plus `inausis.cst` and `board.sdc`, and ends
with `run all` — synthesis, PnR, timing, bitstream and power in one pass. It
takes about ninety seconds.

Reproducing **0x0935** specifically needs the RTL as it stood on 2026-09-09: the
sources in this directory have since gained the AD5254 floor rig
(`digipot_rig.v`, `ad5254_i2c.v`, `digipot_sweep.v`) and the pin and BUILD_ID
changes that came with it. Judge a rebuild by its reports, not by assuming it
matches these.

## The underlying trap

Gowin writes all targets to one `impl/` directory. Synthesising a different top
silently destroys the previous target's reports. This has cost the project its
post-route evidence twice, and came within one build of costing it a third time:
on 2026-09-12 the 0x0935 reports were believed lost because a bring-up build had
overwritten `impl/` before they were archived — they survived only because a copy
had already been taken.

The working package keeps `gowin_syn/impl_archive/<date>_<target>/` copies.

**Archive `impl/` immediately after any run whose numbers will be quoted**, or
build each target in its own working directory.
