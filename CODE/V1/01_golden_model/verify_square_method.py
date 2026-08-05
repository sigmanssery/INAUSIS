import numpy as np
from ttcgs_golden_model import make_test_signal, dog_pipeline

t, x = make_test_signal()
# scale x to 16-bit range like the real fixed-point pipeline does
x16 = x / (np.max(np.abs(x))+1e-9) * 29000
res = dog_pipeline(x16)
feat = res["G_s3"]
fi = np.round(feat).astype(np.int64)   # already in ~16-bit integer range

CAL = 512; N = 3.0

# Method A: float z-score reference
sigma = np.std(feat[:CAL]); mu_f = np.mean(feat[:CAL])
flag_z = np.abs((feat-mu_f)/sigma) > N

# Method B: integer squared comparison (RTL method)
cal = fi[:CAL]
s   = int(np.sum(cal))
ssq = int(np.sum(cal**2))
mu  = s >> 9
var = (ssq >> 9) - mu*mu
N2  = 9
thr = N2 * var
diff = fi - mu
flag_sq = (diff*diff) > thr

mismatch = int(np.sum(flag_z != flag_sq))
print(f"feature integer range: [{fi.min()}, {fi.max()}]")
print(f"mu(int)={mu}  var(int)={var}  sigma_check=sqrt(var)={np.sqrt(max(var,0)):.1f} vs float sigma={sigma:.1f}")
print(f"thr(squared)={thr}")
print(f"z-score flags={flag_z.sum()}  square flags={flag_sq.sum()}  mismatch={mismatch}/{len(feat)}")
if mismatch < len(feat)*0.02:
    print("=> MATCH. squared method valid for RTL.")
else:
    print("=> still mismatch")
