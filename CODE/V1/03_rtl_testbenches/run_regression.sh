#!/usr/bin/env bash
# run_regression.sh — one-shot RTL regression for the INAUSIS/TTCGS datapath.
#
# Requires Icarus Verilog (iverilog + vvp) on PATH. Run from this directory
# (03_rtl_testbenches) so the .mem test vectors and ../02_rtl_production sources
# resolve. On a machine without iverilog, use the EDA Playground bundles in
# ../eda_playground/ instead (see REGRESSION.md).
#
#   ./run_regression.sh
#
set -u
RTL=../02_rtl_production
PASS=0; FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

run() {                      # run <name> <expect-regex> <tb> <src...>
    local name="$1" expect="$2" tb="$3"; shift 3
    local out="$TMP/$name.log"
    if ! iverilog -g2012 -o "$TMP/$name.vvp" "$tb" "$@" >"$TMP/$name.build" 2>&1; then
        printf "  [FAIL] %-18s (compile)\n" "$name"; cat "$TMP/$name.build"; FAIL=$((FAIL+1)); return
    fi
    vvp "$TMP/$name.vvp" >"$out" 2>&1
    if grep -qE "$expect" "$out"; then
        printf "  [PASS] %-18s\n" "$name"; PASS=$((PASS+1))
    else
        printf "  [FAIL] %-18s (expected /%s/)\n" "$name" "$expect"; tail -4 "$out"; FAIL=$((FAIL+1))
    fi
}

echo "=== INAUSIS/TTCGS RTL regression ==="

# --- flag engine (no .mem) ---
run tb_dead      "dead\[0\]=1"                       tb_dead.v       $RTL/zscore_flag_multi.v
run tb_thr_check "PASS"                              tb_thr_check.v  $RTL/zscore_flag_multi.v
run tb_rev_crc   "bad-CRC frame rejected"           tb_rev_crc.v    $RTL/lut_parser.v
# --- flag engine (abs_input.mem) ---
run tb_failsafe  "mask\[2\]=1"                       tb_failsafe.v   $RTL/zscore_flag_multi.v
run tb_mask_check "mask\[2\]=1"                      tb_mask_check.v $RTL/zscore_flag_multi.v
# --- framer / Manchester ---
run tb_packer    "payload_len=51"                    tb_packer.v     $RTL/frame_packer.v $RTL/crc16_ccitt.v
run tb_pack_manch "51-byte frame survived"           tb_pack_manch.v $RTL/frame_packer.v $RTL/crc16_ccitt.v $RTL/manchester_enc.v $RTL/manchester_tx.v $RTL/manchester_rx.v
# --- DSP chain (needs chain_input.mem + dog_coeffs.mem) ---
run tb_chain_lite "un-fed channels .* stayed silent" tb_chain_full_lite.v $RTL/dog_fir_multi.v $RTL/zscore_flag_multi.v $RTL/dsp_chain.v
# --- reverse closed loop ---
run tb_closeloop "closed loop works"                 tb_closeloop.v  $RTL/crc16_ccitt.v $RTL/manchester_enc.v $RTL/manchester_tx.v $RTL/manchester_rx.v $RTL/lut_parser.v $RTL/zscore_flag_multi.v $RTL/halfduplex_ctrl.v
# --- full bidirectional system (needs dog_coeffs.mem) ---
run tb_sys       "full system closed loop works"     tb_sys.v        $RTL/crc16_ccitt.v $RTL/manchester_enc.v $RTL/manchester_tx.v $RTL/manchester_rx.v $RTL/zscore_flag_multi.v $RTL/dog_fir_multi.v $RTL/frame_packer.v $RTL/dsp_chain.v $RTL/lut_parser.v $RTL/halfduplex_ctrl.v $RTL/ttcgs_sys.v
# --- forward self-test top (needs dog_coeffs.mem) ---
run tb_top_lite  "dead wiring OK"                    tb_top_lite.v   $RTL/crc16_ccitt.v $RTL/manchester_enc.v $RTL/manchester_tx.v $RTL/manchester_rx.v $RTL/zscore_flag_multi.v $RTL/dog_fir_multi.v $RTL/frame_packer.v $RTL/dsp_chain.v $RTL/ttcgs_top.v

echo "=== $PASS passed, $FAIL failed ==="
exit $FAIL
