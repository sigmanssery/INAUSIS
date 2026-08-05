# Generate a short input sequence + expected G/DoG outputs for RTL comparison
import numpy as np
from ttcgs_golden_model import make_kernels, SIGMAS, N_TAPS

FRAC = 15
kernels = make_kernels()
kq = [np.round(k*(1<<FRAC)).astype(np.int64) for k in kernels]

# simple test input: step from 0 to 1000 at sample 50, length 400
N = 400
x = np.zeros(N, dtype=np.int64)
x[50:] = 1000

# fixed-point causal FIR exactly as RTL will do it
def fir_fixed(x, kq, frac):
    M = len(kq); out = np.zeros(len(x), dtype=np.int64)
    for n in range(len(x)):
        acc = 0
        for k in range(min(M, n+1)):
            acc += int(x[n-k]) * int(kq[k])
        out[n] = acc >> frac
    return out

G1 = fir_fixed(x, kq[0], FRAC)
G2 = fir_fixed(x, kq[1], FRAC)
G3 = fir_fixed(x, kq[2], FRAC)
DoGf = G1 - G2
DoGs = G2 - G3

# write input vector for RTL testbench
with open("test_input.mem","w") as f:
    for v in x:
        f.write(f"{int(v) & 0xFFFF:04X}\n")

# write expected outputs (decimal) for comparison
np.savez("expected_dog.npz", x=x, G1=G1, G2=G2, G3=G3, DoGf=DoGf, DoGs=DoGs)

# print a few reference points for manual check
print("Reference outputs (fixed-point, what RTL should produce):")
print(f"{'n':>4} {'x':>6} {'G1':>6} {'G2':>6} {'G3':>6} {'DoGf':>6} {'DoGs':>6}")
for n in [49, 50, 51, 55, 60, 100, 200, 399]:
    print(f"{n:>4} {x[n]:>6} {G1[n]:>6} {G2[n]:>6} {G3[n]:>6} {DoGf[n]:>6} {DoGs[n]:>6}")
print(f"\nwrote test_input.mem ({N} samples), expected_dog.npz")
