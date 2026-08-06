# CODE / V1 — RTL, verification, and build

The complete TTCGS datapath: causal multi-scale Difference-of-Gaussians filtering,
z-score significance flagging, framing with CRC, and a single-wire Manchester link
with a CRC-protected reverse channel. Target is a GW1NR-LV9QN88PC6/I5 (Tang Nano 9K)
running directly from its 27 MHz crystal — no PLL.

Everything needed to reproduce the published numbers is here: the golden model the
RTL is checked against, the constraints and scripts that produce the fit and the
timing closure, and the reports those runs actually emitted.

## Layout

```
01_golden_model/       the fixed-point reference — what "verified" means here
02_rtl_production/     synthesizable RTL, board-level top, and the analog SPI cores
  impl/gwsynthesis/    synthesis reports
  impl/pnr/            place-and-route reports — the source of the headline numbers
03_rtl_testbenches/    testbenches, .mem stimulus, regression runner
04_constraints/        pin constraints, timing constraints, synthesis/PnR scripts
05_host_tools/         capture and flashing tools for the assembled board
06_bringup_legacy/     earlier SPI bring-up cores, superseded — see the note below
```

## 01_golden_model — the verification reference

The RTL is not checked against itself. It is checked against a bit-exact
fixed-point model written independently in Python, using the same Q15 coefficients
that are burned into the on-FPGA coefficient ROM.

| File | Role |
|---|---|
| `ttcgs_golden_model.py` | the reference implementation of the whole chain |
| `gen_coeffs.py` | generates `dog_coeffs.mem` (768 × Q15) — the ROM is not a magic blob, it is reproducible from σ₁=2, σ₂=8, σ₃=85 |
| `gen_test_vectors.py`, `gen_abs_vectors.py`, `gen_flag_vectors.py` | stimulus generation for the benches |
| `golden_output.npz`, `expected_flag.npz` | the expected outputs the regression compares against |
| `fixed_point_analysis.py` | produces the **53.3 dB** (DoG_fast) / **62.8 dB** (DoG_slow) SNR figures quoted in the paper |
| `verify_square_method.py` | checks the squared-domain comparison used by the flag engine |
| `run_on_capture.py` | runs the golden model over a real captured CSV rather than synthetic stimulus |
| `make_paper_figs.py` | the measured touch/release and DoG-vs-MA figures, straight from a capture |

`make_paper_figs.py` imports the kernels from `ttcgs_golden_model` rather than
re-deriving them, so the figures show what the coefficient ROM contains. It
reproduces two numbers quoted in the paper from first principles — **12.0 dB**
of additional attenuation at 300 Hz over a 16-tap MA differential, and the MA
staying within **2.5 dB** of its peak across 200–500 Hz — which makes it a check
on those claims rather than an illustration of them.

The MA baseline is `y[n] = x[n] − MA₁₆(x)`, matching `05_figures/make_fig6.py`.
This matters: a difference of two adjacent moving averages is a *band-pass with
nulls*, not a high-pass, and 300 Hz lands in one of those nulls — using it would
invert the sign of the comparison.

It also warns when a capture's native rate is well under 1 kSPS. Upsampling adds
no information, so there is no out-of-band content for the two filters to
separate on and they overlay exactly; the sidelobe-leakage claim can only be
demonstrated on a genuine 1 kSPS capture.

If you want to check one claim in this repository, check this one:
`fixed_point_analysis.py` is where the assertion that Q15 coefficients survive the
subtractive cancellation of a difference of Gaussians is either true or false.

## 02_rtl_production — the design

| Module | Role |
|---|---|
| `dog_fir_multi.v` | three causal Gaussian scales (σ = 2, 8, 85) over 6 channels, all served by **one** time-multiplexed MAC engine and **one** 256-tap circular buffer |
| `zscore_flag_multi.v` | per-dimension z-score against the power-on stationary noise; emits the 18-bit attention mask. Internally 3-stage pipelined (RAM read / multiply / compare-and-writeback) — this is what moved Fmax from 19.5 to 41+ MHz |
| `frame_packer.v` | 51-byte frame at 1 kHz: preamble, timestamp, 18 × 16-bit features, attention mask, dead-channel map, status, CRC-16 |
| `crc16_ccitt.v` | CRC-16-CCITT, shared by forward and reverse paths |
| `manchester_enc.v` / `_tx.v` / `_rx.v` | IEEE 802.3 Manchester; the guaranteed mid-bit transition is also the fail-safe — loss of transitions is loss of link |
| `halfduplex_ctrl.v` | line turnaround for the single conductor |
| `lut_parser.v` | reverse channel: CRC-checked per-dimension threshold updates written back into the flag engine |
| `dsp_chain.v` | DSP-primitive wrapper |

Three tops, for three purposes:

| Top | Purpose |
|---|---|
| `ttcgs_top.v` | forward-only, RX looped back internally — self-test |
| `ttcgs_sys.v` | **the production core** — full bidirectional system |
| `ttcgs_board.v` | **what actually runs on silicon** — `ttcgs_sys` plus both SPI front-ends, a 1 kHz sequencer, and the Manchester line, against real pin constraints |

And the analog front-end cores, current versions:

| File | Notes |
|---|---|
| `ads114s08_spi.v` | `CLK_DIV` 56 (~241 kHz). Slowing the SPI clock cut converter noise ~60× (±97 → ±1.5 LSB); do not speed it back up |
| `ldc1101_spi.v` | **SPI Mode 0**, STATUS read *after* the data registers, POR auto-recovery, and CHIP_ID re-read every sample loop |
| `top_dual.v` | dual-converter readout used for every measured capture in `DATA/`; RP and L median-of-3, sticky STATUS |

`top_dual.v` has a `STREAM_MODE` switch, because the UART, not the converters,
sets the achievable rate. All eight lines are 88 bytes = 880 bits, which at
921600 baud occupies 0.955 ms — 95% of a 1 ms period, and that saturation is
what produced ~12% corrupt reads the last time 1 kHz was attempted.

| mode | streams | period | line load |
|---:|---|---:|---:|
| 0 | both, slots 0–7 | 10 ms | 9.5% |
| 1 | ADS only, slots 0–3 | 1 ms | 48% |
| 2 | LDC only, slots 4–7 | 1 ms | 48% |

One modality at a time is what makes 1 kSPS — the rate the DoG pipeline is
specified at — reachable over this link. Set `TIME_MUX = 0` for either
single-modality mode: it exists to stop two converters contending for one
supply rail, and while it is on the idle core is held in reset for 150 ms at a
time, so the stream carries stale values for half of every cycle.

## Results

Post-route, GW1NR-LV9QN88PC6/I5 @ 27 MHz — reports in `02_rtl_production/impl/pnr/`:

```
3334 logic cells   2107 registers   5 BSRAM   4 DSP
Fmax 45.6 MHz      setup/hold violations: 0
```

The reverse channel costs **+274 logic cells (+10.6%)** over the forward-only
datapath. Closing the inference-to-sensing loop is essentially free.

Fixed-point: Q15 coefficients with a 39-bit accumulator hold the subtractive
cancellation of a difference of Gaussians at **53.3 dB** (DoG_fast) and
**62.8 dB** (DoG_slow) SNR.

## 03_rtl_testbenches — verification

```sh
cd 03_rtl_testbenches
./run_regression.sh
```

11 benches, all passing, checked against `01_golden_model/`.

Icarus Verilog with `-g2012`. **Verilator does not work here**: the benches use
`#` delays and hierarchical memory peeks.

| Bench | Covers |
|---|---|
| `tb_dog_multi` | DoG filter vs golden model |
| `tb_flag_multi`, `tb_thr_check`, `tb_mask_check` | z-score engine, thresholds, mask |
| `tb_packer`, `tb_crc`, `tb_rev_crc` | framing and CRC both directions |
| `tb_manch_48`, `tb_pack_manch`, `tb_halfduplex`, `tb_hd2` | line coding and turnaround |
| `tb_parser`, `tb_closeloop` | reverse LUT updates, full inference-to-sensing loop |
| `tb_dead`, `tb_failsafe` | dead-channel map, loss-of-lock behaviour |
| `tb_sys`, `tb_chain_full` | whole-system integration |

## 04_constraints — reproducing the fit

| File | For |
|---|---|
| `inausis.cst`, `inausis.sdc`, `board.sdc` | `ttcgs_board` — the pin and timing constraints behind the published PnR numbers |
| `syn.tcl`, `syn_sys.tcl` | synthesis of `ttcgs_top` / `ttcgs_sys` |
| `pnr.tcl`, `board_pnr.tcl` | place, route, timing, bitstream |
| `bringup.cst`, `bringup.sdc`, `bringup.tcl` | converter bring-up configuration |
| `dual_bringup.cst`, `dual.tcl` | `top_dual` — the configuration every capture in `DATA/` was taken with |

Run with Gowin `gw_sh`:

```sh
gw_sh syn_sys.tcl      # synthesis fit
gw_sh board_pnr.tcl    # place, route, timing, bitstream
```

Reports land in `impl/gwsynthesis/` and `impl/pnr/`. The committed copies are from
the runs the paper quotes, so a fresh run can be diffed against them.

Gowin **Education** edition works; the SP1 build fails with a licence error.

## 05_host_tools — talking to the assembled board

| Tool | Does |
|---|---|
| `log_dual.py` | captures the UART stream to CSV (schema documented in `DATA/README.md`); `--quiet` for long runs |
| `check_stream.py` | 5-second health check — CHIP_ID, tank stalls, L/RP noise. Run this before trusting any capture |
| `flash.ps1` | flashing with automatic JTAG-channel detection; `-Flash` writes embedded flash instead of SRAM |
| `run_log.ps1`, `run_map.ps1` | wrappers with capture naming, and the live tactile map |

`flash.ps1` exists because `programmer_cli` needs an explicit `--location` and hangs
forever without one — see the repository root README for that and the other
bring-up traps.

## 06_bringup_legacy — superseded, kept for provenance

The first-generation SPI cores. **They contain the bugs that the current versions in
`02_rtl_production/` fix** — most consequentially the SPI mode. Kept because the
traces here are what the diagnosis was made from, not because they should be built.

## A lesson worth recording

The original RTL had only ever been simulated. ROM and state were written with
combinational reads and asynchronous reset; the first synthesis attempt came out at
**38060 LUT4** against a device capacity of 8640. Moving to synchronous reads, block
RAM for the coefficient ROM and sample buffers, and distributed RAM for the
18-dimension flag state is what made it fit.

Clean simulation is not the same as fitting on silicon.
