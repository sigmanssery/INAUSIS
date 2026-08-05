#!/usr/bin/env python3
"""
ttcgs_golden_model.py

GOLDEN MODEL for the INAUSIS / TTCGS tactile front-end DSP pipeline.

This is the "correct answer" reference. It computes, in floating point:
  - three causal Gaussian-smoothed streams  G_s1, G_s2, G_s3
  - DoG_fast = G_s1 - G_s2   (reflex-band feature)
  - DoG_slow = G_s2 - G_s3   (conscious-band feature)
  - per-dimension z-score and significance flag (|z| > N)

Later, the Verilog RTL output will be compared against THIS to confirm the
hardware implementation is numerically correct (within fixed-point tolerance).

Parameters match the paper:  sigma = 2 / 8 / 85,  256 taps, causal,
fs = 1000 SPS,  z-score N = 3, noise estimated over 512 stationary samples,
rate-of-change uses k = 10 samples.
"""

import numpy as np

# ----------------------------------------------------------------------------
# 1. PARAMETERS (match the paper)
# ----------------------------------------------------------------------------
FS       = 1000.0          # sampling rate, samples/s
N_TAPS   = 256             # causal kernel length
SIGMAS   = [2.0, 8.0, 85.0]  # sigma1, sigma2, sigma3
ZSCORE_N = 3.0             # significance threshold (std devs)
NOISE_SAMPLES = 512        # samples used to estimate stationary noise sigma
ROC_K    = 10              # rate-of-change lag (samples) for fast/slow flags


# ----------------------------------------------------------------------------
# 2. CAUSAL GAUSSIAN KERNELS
# ----------------------------------------------------------------------------
def causal_gaussian(sigma, n_taps):
    """
    Causal (single-sided) Gaussian kernel:
        g[n] = exp(-n^2 / (2 sigma^2)),  n = 0..n_taps-1
    normalized so sum(g) = 1.
    Index n=0 is the most recent sample (causal: only looks at past).
    """
    n = np.arange(n_taps)
    g = np.exp(-(n**2) / (2.0 * sigma**2))
    g /= g.sum()
    return g


def make_kernels():
    return [causal_gaussian(s, N_TAPS) for s in SIGMAS]


# ----------------------------------------------------------------------------
# 3. CAUSAL CONVOLUTION (FIR)
# ----------------------------------------------------------------------------
def causal_fir(x, kernel):
    """
    Apply causal FIR: y[n] = sum_{k=0}^{M-1} kernel[k] * x[n-k].
    kernel[0] weights the current sample x[n], kernel[k] weights x[n-k].
    Uses zero-padding for n-k < 0 (startup transient).
    """
    M = len(kernel)
    y = np.zeros_like(x, dtype=float)
    for n in range(len(x)):
        acc = 0.0
        kmax = min(M, n + 1)
        for k in range(kmax):
            acc += kernel[k] * x[n - k]
        y[n] = acc
    return y


def causal_fir_fast(x, kernel):
    """Vectorized version of causal_fir using np.convolve (same result)."""
    full = np.convolve(x, kernel)        # length len(x)+M-1
    return full[:len(x)]                 # causal: take first len(x) samples


# ----------------------------------------------------------------------------
# 4. DoG PIPELINE
# ----------------------------------------------------------------------------
def dog_pipeline(x):
    """
    Given raw signal x, compute the three smoothed streams and the two DoG
    features. Returns dict with G1,G2,G3, DoG_fast, DoG_slow.
    """
    kernels = make_kernels()
    G1 = causal_fir_fast(x, kernels[0])
    G2 = causal_fir_fast(x, kernels[1])
    G3 = causal_fir_fast(x, kernels[2])
    return {
        "G_s1": G1,
        "G_s2": G2,
        "G_s3": G3,
        "DoG_fast": G1 - G2,    # reflex band
        "DoG_slow": G2 - G3,    # conscious band
    }


# ----------------------------------------------------------------------------
# 5. Z-SCORE SIGNIFICANCE FLAG
# ----------------------------------------------------------------------------
def zscore_flag(feature, noise_sigma, N=ZSCORE_N, mode="abs", k=ROC_K, debounce=1):
    """
    Compute significance flag for a feature stream.
      mode="abs"  : flag = |z[n]| > N            (for slow / G_s3 trend)
      mode="roc"  : flag = |z[n] - z[n-k]| > N    (for DoG_fast / DoG_slow)
    z[n] = feature[n] / noise_sigma

    debounce: require this many CONSECUTIVE samples above threshold before
    raising the flag. This suppresses the false triggers caused by the
    differential (rate-of-change) mode amplifying noise by ~sqrt(2): random
    noise rarely exceeds threshold for several samples in a row, but a real
    tactile event sustains. debounce=1 disables it.

    Returns (z, flag_bool).
    """
    z = feature / noise_sigma if noise_sigma > 0 else np.zeros_like(feature)
    if mode == "abs":
        raw = np.abs(z) > N
    elif mode == "roc":
        raw = np.zeros_like(z, dtype=bool)
        raw[k:] = np.abs(z[k:] - z[:-k]) > N
    else:
        raise ValueError("mode must be 'abs' or 'roc'")

    if debounce <= 1:
        return z, raw

    # consecutive-sample confirmation
    flag = np.zeros_like(raw, dtype=bool)
    cnt = 0
    for i in range(len(raw)):
        cnt = cnt + 1 if raw[i] else 0
        flag[i] = cnt >= debounce
    return z, flag


def estimate_noise_sigma(feature, n_samples=NOISE_SAMPLES):
    """Estimate stationary noise std from the first n_samples (sensor at rest)."""
    return np.std(feature[:n_samples])


def estimate_noise_sigma_roc(feature, k=ROC_K, n_samples=NOISE_SAMPLES):
    """Noise sigma of the ROC COMPARISON quantity x[n]-x[n-k] (NOT the feature).
    ROC flags compare the difference, whose variance is ~2x the feature's, so
    calibrating on the feature made ROC bands fire at ~2.1 sigma instead of N.
    Calibrating on the difference makes it a true N-sigma, per band. Mirrors the
    RTL, which accumulates the difference during calibration; the first k samples
    use x[n-k]=0 (zero-init ROC buffer)."""
    diff = feature.astype(float).copy()
    diff[k:] = feature[k:] - feature[:-k]
    return np.std(diff[:n_samples])


# ----------------------------------------------------------------------------
# 6. TEST SIGNAL GENERATOR (simulates a touch/release sequence)
# ----------------------------------------------------------------------------
def make_test_signal(duration_s=2.5, fs=FS, seed=0):
    """
    Build a synthetic tactile signal with distinct phases so each DoG band
    has something to respond to:
      - LONG stationary rest (>=512 samples) -> clean noise estimate
      - step up (touch onset)                 -> fast + slow transient
      - sustained plateau (grasp)             -> G_s3 holds, DoG -> 0
      - small high-freq vibration (texture)   -> fast band responds
      - step down (release)                   -> fast + slow transient
      - rest

    NOTE: the rest phase MUST be at least NOISE_SAMPLES long and contain NO
    touch, otherwise the noise-sigma estimate is corrupted and the z-score
    flags never trigger. This mirrors the real device requirement that the
    512-sample power-on noise calibration happens while the sensor is at rest.
    """
    rng = np.random.default_rng(seed)
    n = int(duration_s * fs)
    t = np.arange(n) / fs
    x = np.zeros(n)

    noise = rng.normal(0, 0.01, n)            # baseline sensor noise

    # phase boundaries (in samples) -- rest phase is 0.60s (600 > 512 samples)
    p_rest1  = int(0.60 * fs)   # 0.00-0.60 s rest  (>=512 samples, clean)
    p_touch  = int(0.65 * fs)   # 0.60-0.65 s rising edge (touch)
    p_grasp  = int(1.30 * fs)   # 0.65-1.30 s sustained grasp
    p_vib    = int(1.60 * fs)   # 1.30-1.60 s vibration burst on top of grasp
    p_rel    = int(1.65 * fs)   # 1.60-1.65 s falling edge (release)
    # 1.65-2.50 s rest

    # touch rising edge (smooth ramp)
    x[p_rest1:p_touch] = np.linspace(0, 1.0, p_touch - p_rest1)
    # sustained grasp
    x[p_touch:p_rel]   = 1.0
    # texture vibration (e.g. 40 Hz) during p_vib..p_rel on top of plateau
    vib_idx = np.arange(p_vib, p_rel)
    x[p_vib:p_rel] += 0.08 * np.sin(2*np.pi*40*(vib_idx/fs))
    # release falling edge
    x[p_rel:p_rel+int(0.05*fs)] = np.linspace(1.0, 0.0, int(0.05*fs))

    x = x + noise
    return t, x


# ----------------------------------------------------------------------------
# 7. RUN + REPORT
# ----------------------------------------------------------------------------
def main():
    t, x = make_test_signal()
    res = dog_pipeline(x)

    # noise sigma per feature (estimated on the rest phase). ROC bands calibrate
    # on the DIFFERENCE quantity they actually compare (fixes the ~sqrt(2) under-
    # threshold); the ABS band calibrates on the feature itself.
    sig_fast = estimate_noise_sigma_roc(res["DoG_fast"])
    sig_slow = estimate_noise_sigma_roc(res["DoG_slow"])
    sig_g3   = estimate_noise_sigma(res["G_s3"])

    z_fast, fl_fast = zscore_flag(res["DoG_fast"], sig_fast, mode="roc", debounce=3)
    z_slow, fl_slow = zscore_flag(res["DoG_slow"], sig_slow, mode="roc", debounce=3)
    z_g3,   fl_g3   = zscore_flag(res["G_s3"],     sig_g3,   mode="abs", debounce=3)

    print("=== TTCGS GOLDEN MODEL ===")
    print(f"taps={N_TAPS}, sigmas={SIGMAS}, fs={FS}, N={ZSCORE_N}")
    print(f"noise_sigma  DoG_fast={sig_fast:.5f}  DoG_slow={sig_slow:.5f}  G_s3={sig_g3:.5f}")
    print(f"flags raised  fast={fl_fast.sum()}  slow={fl_slow.sum()}  g3={fl_g3.sum()}  (out of {len(x)})")

    # sanity: peak DoG_fast should occur near touch (0.30-0.35s) & release (1.30s)
    pk_fast = t[np.argmax(np.abs(res["DoG_fast"]))]
    pk_slow = t[np.argmax(np.abs(res["DoG_slow"]))]
    print(f"peak |DoG_fast| at t={pk_fast:.3f}s   peak |DoG_slow| at t={pk_slow:.3f}s")

    # save arrays for later RTL comparison
    np.savez("golden_output.npz",
             t=t, x=x,
             G_s1=res["G_s1"], G_s2=res["G_s2"], G_s3=res["G_s3"],
             DoG_fast=res["DoG_fast"], DoG_slow=res["DoG_slow"],
             z_fast=z_fast, z_slow=z_slow, z_g3=z_g3,
             fl_fast=fl_fast, fl_slow=fl_slow, fl_g3=fl_g3)
    print("saved golden_output.npz")

    return t, x, res, (z_fast, fl_fast, z_slow, fl_slow, z_g3, fl_g3)


if __name__ == "__main__":
    main()
