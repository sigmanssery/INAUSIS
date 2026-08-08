# impl/ — what these reports actually are

**Read this before quoting a number out of this directory.**

Everything here is a single coherent `ttcgs_board` run from **2026-08-08**. The
place-and-route evidence that this directory previously lacked is now present.

## The run

| | |
|---|---|
| Top module | `ttcgs_board` |
| Device | GW1NR-LV9QN88PC6/I5 (GW1NR-9, version C) |
| Physical constraints | `inausis.cst` |
| Timing constraints | `board.sdc` |
| Tool | GowinSynthesis + Gowin PnR, V1.9.11.03 Education |
| Date | 2026-08-08 |
| Errors / warnings | none |

Verify before quoting: `project.rpt.txt`'s `<Physical Constraints File>` must say
`inausis.cst`. If it says `dual_bringup.cst`, a bring-up build has overwritten
this directory again — see the trap at the bottom.

## Post-route results

```
Logic       3400/8640  (40%)     2692 LUT/ALU/ROM16  (2372 LUT, 320 ALU)
Register    2124/6693  (32%)     2115 logic FF + 9 I/O FF, 0 latches
BSRAM          5/26    (20%)
DSP            4/10    (40%)     1 MULTADDALU18X18, 1 ALU54D

clk27       constraint 27.000 MHz     actual Fmax 43.920 MHz     logic level 7
TNS         setup 0.000 (0 endpoints)   hold 0.000 (0 endpoints)
worst slack setup +14.269 ns            hold +0.479 ns

Power       36.521 mW total  =  26.677 quiescent + 9.844 dynamic
            junction 25.75 °C, Theta-JA 21.45
```

## Against the previously-quoted figures

The headline numbers in the top-level README were reported from a run whose
output had been overwritten. They are now reproduced, and they were substantially
right:

| | previously quoted | this run | |
|---|---:|---:|---|
| Logic cells | 3334 | **3400** | +2.0% |
| Registers | 2107 | **2124** | +0.8% |
| BSRAM | 5 | **5** | exact |
| DSP | 4 | **4** | exact |
| Fmax | 45.6 MHz | **43.920 MHz** | −3.7% |
| Timing violations | 0 | **0** | exact |
| FPGA core power | ~36 mW | **36.521 mW** | exact |

The three that moved are all small and in the direction RTL growth predicts —
`ldc1101_spi.v` gained a `chip_id` output and re-read state since the original
run, and `ads114s08_spi.v` changed. **The current numbers are the ones to cite.**
Nothing about the old figures needs withdrawing; they were simply stale.

## The reverse-channel cost

`+274 logic cells (+10.6%)` is a difference between two builds, so it needs both.
Both were re-synthesised on 2026-08-08 (`syn.tcl` → `ttcgs_top`, `syn_sys.tcl` →
`ttcgs_sys`; synthesis only, no PnR):

| | Logic | LUT | ALU | RAM16 | FF | BSRAM | DSP |
|---|---:|---:|---:|---:|---:|---:|---:|
| `ttcgs_top` forward | 2585 | 1648 | 229 | 118 | 1501 | 3 | 3 |
| `ttcgs_sys` bidirectional | 2859 | 1886 | 265 | 118 | 1641 | 5 | 3 |
| difference | **+274** | +238 | +36 | 0 | **+140** | +2 | 0 |

`+274 / 2585 = 10.60%`, and `+140 / 1501 = 9.33%` — both as published.

These two are **unchanged** from the 2026-07-17 run, while the board-level
figures moved. That is consistent rather than odd: neither top instantiates
`ads114s08_spi` or `ldc1101_spi`, so the SPI-core changes that grew
`ttcgs_board` do not reach the datapath tops.

Gowin's `Logic` column counts `LUT + ALU + ROM16 + 6 × RAM16`, which is why it
exceeds the LUT+ALU sum. Check against the board run: `2372 + 320 + 0 + 6×118 =
3400`.

Reports archived at `gowin_syn/impl_archive/2026-08-08_ttcgs_top_syn/` and
`..._ttcgs_sys_syn/`. They are **not** copied into this directory, which holds
the `ttcgs_board` run only.

## `gwsynthesis/`

Synthesis-stage output for the same `ttcgs_board` run. It is a *synthesis fit*,
not a place-and-route result — where the two disagree, `pnr/` is authoritative.

## To repeat the run

```sh
cd CODE/V1/02_rtl_production      # or gowin_syn/ in the working package
gw_sh board_pnr.tcl
```

`board_pnr.tcl` lists all fourteen sources plus `inausis.cst` and `board.sdc`,
and ends with `run all` — synthesis, PnR, timing, bitstream, and power in one
pass. It takes about ninety seconds.

## The underlying trap

Gowin writes all targets to one `impl/` directory. Synthesising a different top
silently destroys the previous target's reports. This has cost the project its
post-route evidence twice.

The working package now keeps `gowin_syn/impl_archive/<date>_<target>/` copies:

```
2026-08-07_pre-ttcgs-board_top_dual/    the bring-up run this replaced
2026-08-08_ttcgs_board_pnr/             the run documented above
```

**Archive `impl/` immediately after any run whose numbers will be quoted**, or
build each target in its own working directory.
