# Generate the RTL comparison vectors for dog_fir_multi.
#
# Three things this must get right, each of which it previously did not:
#
#   1. Coefficients come from dog_coeffs.mem, the same file the RTL loads with
#      $readmemh. Re-quantising the kernels here produced a second, independent
#      rounding, so after gen_coeffs.py gained its sum-normalisation the vectors
#      silently described a different filter from the one in the ROM.
#
#   2. The datapath saturates to 16 bits at the accumulator shift and again at
#      each difference. Modelling those in full precision hid the overflow that
#      turned a sustained full-scale press into -32763 on hardware.
#
#   3. The stimulus reaches full scale. The previous step to 1000 never came
#      near the range where either overflow can occur, which is why the
#      "bit-exact" comparison passed while the hardware wrapped.
import numpy as np
from ttcgs_golden_model import N_TAPS

FRAC = 15

def load_coeffs(path="dog_coeffs.mem"):
    v = [int(x, 16) for x in open(path).read().split()]
    v = [x - 65536 if x > 32767 else x for x in v]
    n = len(v) // 3
    return [np.array(v[i*n:(i+1)*n], dtype=np.int64) for i in range(3)]

def sat16(v):
    return np.clip(v, -32768, 32767).astype(np.int64)

def fir_fixed(x, kq, frac):
    M = len(kq); out = np.zeros(len(x), dtype=np.int64)
    for n in range(len(x)):
        acc = 0
        for k in range(min(M, n + 1)):
            acc += int(x[n - k]) * int(kq[k])
        out[n] = acc >> frac          # arithmetic shift, as the RTL does
    return sat16(out)                 # then saturate to the 16-bit register

kq = load_coeffs()
for i, k in enumerate(kq):
    assert k.sum() == (1 << FRAC), "kernel %d sums to %d, not %d" % (i, k.sum(), 1 << FRAC)

# stimulus: the original small step (regression), then both rails, then a ramp
seg = []
seg.append(np.zeros(50, dtype=np.int64))
seg.append(np.full(150, 1000, dtype=np.int64))       # original case
seg.append(np.zeros(100, dtype=np.int64))
seg.append(np.full(200, 32767, dtype=np.int64))      # positive full scale
seg.append(np.zeros(100, dtype=np.int64))
seg.append(np.full(200, -32768, dtype=np.int64))     # negative full scale
seg.append(np.zeros(100, dtype=np.int64))
seg.append(np.linspace(-32768, 32767, 300).astype(np.int64))   # ramp across range
seg.append(np.zeros(100, dtype=np.int64))
x = np.concatenate(seg)
N = len(x)

G1, G2, G3 = (fir_fixed(x, kq[i], FRAC) for i in range(3))
DoGf = sat16(G1.astype(np.int64) - G2.astype(np.int64))
DoGs = sat16(G2.astype(np.int64) - G3.astype(np.int64))

with open("test_input.mem", "w") as f:
    for v in x:
        f.write("%04X\n" % (int(v) & 0xFFFF))
np.savez("expected_dog.npz", x=x, G1=G1, G2=G2, G3=G3, DoGf=DoGf, DoGs=DoGs)

print("coefficients from dog_coeffs.mem, sums %s" % [int(k.sum()) for k in kq])
print("stimulus %d samples, range %d..%d" % (N, x.min(), x.max()))
for nm, v in [("G1", G1), ("G2", G2), ("G3", G3), ("DoGf", DoGf), ("DoGs", DoGs)]:
    hit = int(((v == 32767) | (v == -32768)).sum())
    print("  %-5s range %7d..%6d   saturated on %d samples" % (nm, v.min(), v.max(), hit))
print("wrote test_input.mem (%d) and expected_dog.npz" % N)
