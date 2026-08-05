import numpy as np
from ttcgs_golden_model import (make_test_signal, dog_pipeline,
                                 NOISE_SAMPLES, ROC_K)

t, x = make_test_signal()
res = dog_pipeline(x)
feat = res["DoG_fast"]

# scale DoG_fast to integer (RTL works in integer DoG units).
# golden DoG_fast is float ~0..0.7; the RTL DoG comes from Q15 FIR as int.
# Use the same scaling as the fixed-point analysis: input scaled to 16-bit.
# For a standalone flag test, scale feat to a reasonable integer range.
SCALE = 10000.0
feat_i = np.round(feat * SCALE).astype(np.int64)
# clip to 16-bit signed
feat_i = np.clip(feat_i, -32768, 32767)

N = 3.0; N_SQ = 9; k = ROC_K; DEB = 3
CAL_N = NOISE_SAMPLES

# RTL-equivalent calibration. DoG_fast is a ROC dim, and the RTL now calibrates
# on the DIFFERENCE it actually compares (x[n]-x[n-k], with x[n-k]=0 for n<k,
# matching the zero-init ROC buffer) — NOT the feature. This fixes the ~sqrt(2)
# under-threshold; keep the generator in step or tb_flag_multi will mismatch.
cmp_cal = np.array([int(feat_i[n]) - (int(feat_i[n-k]) if n >= k else 0)
                    for n in range(CAL_N)], dtype=np.int64)
csum = int(np.sum(cmp_cal))
csumsq = int(np.sum(cmp_cal**2))
mean_sq_term = (csum*csum)//CAL_N
variance_int = (csumsq - mean_sq_term)//CAL_N
threshold = (N_SQ * (csumsq - mean_sq_term))//CAL_N
print(f"calibration: sum={csum} sumsq={csumsq} var_int={variance_int} thr={threshold}")

# RTL-equivalent run: ROC squared compare + debounce
flag = np.zeros(len(feat_i), dtype=int)
deb = 0
for n in range(len(feat_i)):
    if n < CAL_N:
        continue
    if n >= k:
        cmp = int(feat_i[n]) - int(feat_i[n-k])
    else:
        cmp = 0
    cmp_sq = cmp*cmp
    if cmp_sq > threshold:
        if deb >= DEB-1:
            flag[n] = 1
        else:
            deb += 1
            flag[n] = 0
    else:
        deb = 0
        flag[n] = 0

# write DoG values for RTL input
with open("flag_input.mem","w") as f:
    for v in feat_i:
        f.write(f"{int(v) & 0xFFFF:04X}\n")
np.savez("expected_flag.npz", feat=feat_i, flag=flag, threshold=threshold)

print(f"total samples={len(feat_i)}, flags raised={flag.sum()}")
print("sample flag points (n, dog, flag):")
fired = np.where(flag==1)[0]
print(f"  first few fired indices: {fired[:10].tolist()}")
print(f"wrote flag_input.mem, expected_flag.npz")
