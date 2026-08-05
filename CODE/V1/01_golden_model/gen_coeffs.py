import numpy as np
from ttcgs_golden_model import make_kernels, SIGMAS, N_TAPS

FRAC = 15  # Q15
kernels = make_kernels()

# Quantize each kernel to Q15 signed integers
print("=== Q15 coefficient generation ===")
print(f"taps={N_TAPS}, sigmas={SIGMAS}, Q{FRAC}\n")

all_coeffs = {}
for s, k in zip(SIGMAS, kernels):
    q = np.round(k * (1 << FRAC)).astype(int)
    all_coeffs[s] = q
    nz = np.sum(q != 0)
    print(f"sigma={s:5.1f}: nonzero taps={nz:3d}/{N_TAPS}, "
          f"max={q.max()}, sum={q.sum()} (ideal {1<<FRAC}={32768})")

# Generate Verilog memory init file (one hex value per line, 16-bit signed two's complement)
# Order: sigma1[0..255], sigma2[0..255], sigma3[0..255]  => 768 entries
def to_hex16(v):
    return f"{v & 0xFFFF:04X}"

lines = []
for s in SIGMAS:
    for v in all_coeffs[s]:
        lines.append(to_hex16(int(v)))

with open("dog_coeffs.mem", "w") as f:
    f.write("\n".join(lines) + "\n")

print(f"\nWrote dog_coeffs.mem: {len(lines)} entries (3 sigmas x 256 taps)")
print("Format: 16-bit signed two's complement hex, one per line")
print("Layout: [sigma2 taps 0-255][sigma8 taps 0-255][sigma85 taps 0-255]")

# Also dump first few coeffs of each for sanity
print("\nFirst 5 Q15 coeffs each kernel:")
for s in SIGMAS:
    print(f"  sigma={s:5.1f}: {all_coeffs[s][:5].tolist()}")
