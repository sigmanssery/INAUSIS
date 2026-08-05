#!/usr/bin/env python3
"""
fixed_point_analysis.py

Analyze how fixed-point (integer) arithmetic on the FPGA degrades the DoG
pipeline versus the floating-point golden model. Three things are checked:

  1. COEFFICIENT QUANTIZATION
     Gaussian coefficients are fractions < 1. On FPGA they are stored as
     Q-format integers (value * 2^FRAC). Small tail coefficients of the wide
     kernel (sigma=85) may quantize to zero. How many are lost, and does it
     matter (since sum must stay ~1)?

  2. ACCUMULATOR WIDTH
     256-tap MAC sum. With input as signed 16-bit and Q15 coefficients, the
     product is ~31-bit; summing 256 of them needs +8 bits headroom. What
     accumulator width avoids overflow?

  3. DoG SUBTRACTION CANCELLATION  <-- the dangerous one
     DoG_fast = G_s1 - G_s2. Both are close to the input, so their difference
     is small and loses significant bits. Quantization noise that was tiny
     relative to G_s1 becomes large relative to the small DoG. We measure the
     actual SNR / error of the fixed-point DoG vs the float DoG.

The conclusion tells you whether the paper's "256 tap, single DSP, 16-bit"
claim survives in fixed point, and what FRAC / accumulator width to use.
"""

import numpy as np
from ttcgs_golden_model import (make_test_signal, make_kernels, causal_fir_fast,
                                 dog_pipeline, SIGMAS, N_TAPS, FS)

# ----------------------------------------------------------------------------
# Q-format helpers
# ----------------------------------------------------------------------------
def quantize(x, frac_bits):
    """Quantize float x to Q-format with `frac_bits` fractional bits."""
    scale = (1 << frac_bits)
    return np.round(x * scale).astype(np.int64)

def dequantize(q, frac_bits):
    return q.astype(np.float64) / (1 << frac_bits)


# ----------------------------------------------------------------------------
# 1. COEFFICIENT QUANTIZATION ANALYSIS
# ----------------------------------------------------------------------------
def analyze_coeffs(frac_bits=15):
    print("="*68)
    print(f"1. COEFFICIENT QUANTIZATION  (Q{frac_bits}, i.e. coeff*2^{frac_bits})")
    print("="*68)
    kernels = make_kernels()
    for s, k in zip(SIGMAS, kernels):
        q = quantize(k, frac_bits)
        n_zero = np.sum(q == 0)
        # reconstructed sum (should be ~1.0)
        recon_sum = dequantize(q, frac_bits).sum()
        max_c = k.max(); min_nonzero = k[k > 0].min()
        print(f"  sigma={s:5.1f}: taps={len(k)}  zeroed={n_zero:3d}/{len(k)}  "
              f"sum={recon_sum:.5f}  max_coef={max_c:.4e}  min_coef={min_nonzero:.2e}")
    print("  -> 'zeroed' = tail coefficients quantized to 0. If sum stays ~1.0,")
    print("     the lost tail energy is negligible (those taps barely contributed).")
    print()


# ----------------------------------------------------------------------------
# 2. ACCUMULATOR WIDTH
# ----------------------------------------------------------------------------
def analyze_accumulator(frac_bits=15, in_bits=16):
    print("="*68)
    print("2. ACCUMULATOR WIDTH")
    print("="*68)
    # worst case: input at full scale, all taps same sign
    in_max = (1 << (in_bits-1)) - 1            # signed 16-bit max
    coef_max = (1 << frac_bits)                # Q15 representation of 1.0
    # but coefficients sum to 1.0, so worst-case sum of products is in_max * 1.0
    # in Q-format: in_max * 2^frac. Still, per-product max = in_max * coef_max.
    prod_max = in_max * coef_max
    prod_bits = int(np.ceil(np.log2(prod_max))) + 1
    # 256 accumulations add up to log2(256)=8 bits, BUT since coeffs sum to 1,
    # the true accumulated value <= in_max * 2^frac (not 256x). Still size for safety.
    acc_worst = in_max * coef_max              # coeffs sum to 1 => bounded
    acc_bits_safe = int(np.ceil(np.log2(prod_max))) + 8 + 1  # +8 for 256 taps, +1 sign
    acc_bits_real = int(np.ceil(np.log2(acc_worst))) + 1
    print(f"  input: signed {in_bits}-bit (max {in_max})")
    print(f"  coeff: Q{frac_bits} (1.0 = {coef_max})")
    print(f"  single product max = {prod_max} -> {prod_bits} bits")
    print(f"  worst-case accumulator (coeffs sum=1) = {acc_worst} -> {acc_bits_real} bits")
    print(f"  SAFE accumulator width (paranoid, +8 for 256 taps) = {acc_bits_safe} bits")
    print(f"  -> use a {acc_bits_safe}-bit signed accumulator; truncate back to")
    print(f"     {in_bits}-bit after >> {frac_bits} (remove the Q scaling).")
    print()


# ----------------------------------------------------------------------------
# 3. DoG SUBTRACTION CANCELLATION  (the critical test)
# ----------------------------------------------------------------------------
def fixed_point_fir(x_q, kernel_q, frac_bits, out_shift):
    """
    Fully integer causal FIR, mimicking FPGA:
      acc = sum( x_q[n-k] * kernel_q[k] )   (integer)
      y_q = acc >> out_shift                 (rescale)
    x_q: integer input (already quantized)
    kernel_q: integer Q-format coefficients
    out_shift: bits to shift down to undo the coefficient Q scaling
    """
    M = len(kernel_q)
    N = len(x_q)
    y = np.zeros(N, dtype=np.int64)
    for n in range(N):
        acc = np.int64(0)
        kmax = min(M, n+1)
        # vectorized inner product
        seg_x = x_q[n-kmax+1:n+1][::-1]      # x[n], x[n-1], ...
        seg_k = kernel_q[:kmax]
        acc = np.int64(np.dot(seg_x.astype(np.int64), seg_k.astype(np.int64)))
        y[n] = acc >> out_shift
    return y

def analyze_dog_subtraction(frac_bits=15, in_bits=16):
    print("="*68)
    print("3. DoG SUBTRACTION CANCELLATION  (the dangerous one)")
    print("="*68)

    # build test signal, scale to fixed-point input range
    t, x = make_test_signal()
    in_max = (1 << (in_bits-1)) - 1
    # map x (roughly 0..1 plus noise) to signed 16-bit, leave headroom
    x_scaled = x / (np.max(np.abs(x)) + 1e-9) * (in_max * 0.9)
    x_q = np.round(x_scaled).astype(np.int64)

    # float reference
    res_float = dog_pipeline(x_scaled)   # use scaled float as reference

    # fixed-point kernels
    kernels = make_kernels()
    kq = [quantize(k, frac_bits) for k in kernels]

    # fixed-point smoothed streams
    G1q = fixed_point_fir(x_q, kq[0], frac_bits, frac_bits)
    G2q = fixed_point_fir(x_q, kq[1], frac_bits, frac_bits)
    G3q = fixed_point_fir(x_q, kq[2], frac_bits, frac_bits)

    # fixed-point DoG (integer subtraction)
    DoGfast_q = G1q - G2q
    DoGslow_q = G2q - G3q

    # compare to float
    def err_stats(name, fixed, flt):
        fixed_f = fixed.astype(float)
        e = fixed_f - flt
        rms_sig = np.sqrt(np.mean(flt**2))
        rms_err = np.sqrt(np.mean(e**2))
        snr = 20*np.log10(rms_sig / (rms_err + 1e-12))
        peak = np.max(np.abs(flt))
        print(f"  {name:10}  signal_rms={rms_sig:10.2f}  err_rms={rms_err:8.3f}  "
              f"peak={peak:10.2f}  SNR={snr:6.1f} dB")
        return snr

    print(f"  (Q{frac_bits} coefficients, {in_bits}-bit input, integer MAC)\n")
    print("  Smoothed streams (should be near-perfect, large signal):")
    err_stats("G_s1", G1q, res_float["G_s1"])
    err_stats("G_s2", G2q, res_float["G_s2"])
    err_stats("G_s3", G3q, res_float["G_s3"])
    print("\n  DoG features (THE TEST - small signal from subtraction):")
    snr_fast = err_stats("DoG_fast", DoGfast_q, res_float["DoG_fast"])
    snr_slow = err_stats("DoG_slow", DoGslow_q, res_float["DoG_slow"])

    print()
    print("  INTERPRETATION:")
    print("   - SNR > 40 dB  : excellent, fixed point is essentially lossless here")
    print("   - SNR 20-40 dB : acceptable, DoG shape preserved, minor noise")
    print("   - SNR < 20 dB  : cancellation is hurting; need more frac bits or")
    print("                    wider input. Paper's claim would be at risk.")
    return snr_fast, snr_slow


# ----------------------------------------------------------------------------
# 4. SWEEP frac_bits to find the minimum that keeps DoG SNR healthy
# ----------------------------------------------------------------------------
def sweep_frac_bits():
    print("="*68)
    print("4. FRAC-BITS SWEEP  (find minimum Q that keeps DoG healthy)")
    print("="*68)
    t, x = make_test_signal()
    in_bits = 16
    in_max = (1 << (in_bits-1)) - 1
    x_scaled = x / (np.max(np.abs(x))+1e-9) * (in_max*0.9)
    x_q = np.round(x_scaled).astype(np.int64)
    res_float = dog_pipeline(x_scaled)
    kernels = make_kernels()

    print(f"  {'Q':>4} | {'DoG_fast SNR':>13} {'DoG_slow SNR':>13}")
    print("  " + "-"*36)
    for frac in [8, 10, 12, 15, 18]:
        kq = [quantize(k, frac) for k in kernels]
        G1=fixed_point_fir(x_q,kq[0],frac,frac)
        G2=fixed_point_fir(x_q,kq[1],frac,frac)
        G3=fixed_point_fir(x_q,kq[2],frac,frac)
        df=(G1-G2).astype(float); ds=(G2-G3).astype(float)
        def snr(fx,fl):
            e=fx-fl; return 20*np.log10(np.sqrt(np.mean(fl**2))/(np.sqrt(np.mean(e**2))+1e-12))
        print(f"  {frac:>4} | {snr(df,res_float['DoG_fast']):>13.1f} {snr(ds,res_float['DoG_slow']):>13.1f}")
    print()


if __name__ == "__main__":
    analyze_coeffs(frac_bits=15)
    analyze_accumulator(frac_bits=15, in_bits=16)
    analyze_dog_subtraction(frac_bits=15, in_bits=16)
    sweep_frac_bits()
