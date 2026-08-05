# CODE / V1 — RTL and verification

The complete TTCGS datapath: causal multi-scale Difference-of-Gaussians filtering,
z-score significance flagging, framing with CRC, and a single-wire Manchester link
with a CRC-protected reverse channel. Target is a GW1NR-LV9QN88PC6/I5 (Tang Nano 9K)
running directly from its 27 MHz crystal — no PLL.

## Layout

```
02_rtl_production/     synthesizable RTL — the design proper
  impl/gwsynthesis/    GowinSynthesis output and resource reports
03_rtl_testbenches/    testbenches, .mem stimulus, regression runner
06_bringup_legacy/     SPI bring-up cores for the two converters, kept for reference
```

## The design

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
| `ttcgs_top.v` | forward-only top (RX looped back internally) — self-test configuration |
| `ttcgs_sys.v` | **production top** — full bidirectional system |

`ttcgs_sys` is the one to build. `ttcgs_top` exists so the forward path can be
exercised without a downstream partner.

## Results

Post-route, GW1NR-LV9QN88PC6/I5 @ 27 MHz:

```
3334 logic cells   2107 registers   5 BSRAM   4 DSP
Fmax 45.6 MHz      setup/hold violations: 0
```

The reverse channel costs **+274 logic cells (+10.6%)** over the forward-only
datapath. Closing the inference-to-sensing loop is essentially free.

Fixed-point: Q15 coefficients with a 39-bit accumulator hold the subtractive
cancellation of a difference of Gaussians at **53.3 dB** (DoG_fast) and
**62.8 dB** (DoG_slow) SNR.

## Verification

```sh
cd 03_rtl_testbenches
./run_regression.sh
```

11 benches, all passing, checked against a bit-exact fixed-point golden model —
the same Q15 coefficients that are burned into the on-FPGA coefficient ROM
(`dog_coeffs.mem`, 768 entries).

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

## A lesson worth recording

The original RTL had only ever been simulated. ROM and state were written with
combinational reads and asynchronous reset; the first synthesis attempt came out at
**38060 LUT4** against a device capacity of 8640. Moving to synchronous reads, block
RAM for the coefficient ROM and sample buffers, and distributed RAM for the
18-dimension flag state is what made it fit.

Clean simulation is not the same as fitting on silicon.

## `06_bringup_legacy/`

The SPI cores used to bring the two converters up on real hardware, kept separate
from the production datapath. `ldc1101_spi.v` and `ads114s08_spi.v` here are the
bring-up lineage; see the repository root README for the non-obvious details each
one cost to get right (SPI mode, register read ordering, and how a floating MISO
disguises itself as a stalled tank).
