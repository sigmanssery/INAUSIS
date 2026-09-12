# -*- coding: utf-8 -*-
"""v25 的三張新圖,全部從本機既有錄製算出。

Fig A  前端解析度 vs 操作者執行變異
       產生器 = data/v12/synth_floor.csv(phase 0,上升時間掃描)
       操作者 = gowin_syn/2026-08-28_FSR402_modC1..C6(語料庫 C 類 48 次按壓,raw 在 d2)
Fig B  偵測下限。**排除 step 24** —— 它的 raw 沒有刺激,d2 是前一步 28000 counts
       按壓的慢帶尾巴(318 單調衰減到 8),那 5/5 的偵測是假的。
Fig C  守衛鎖死 A/B(sus2_v10 vs sus2_v12)
"""
import os, glob
import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

D   = r"C:\Users\Admin\Desktop\INAUSIS\data"
G   = r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_package\INAUSIS_package\gowin_syn"
OUT = r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_repo\DATA\figs"
FS  = 689.0
SAMP_MS = 1000.0 / FS
os.makedirs(OUT, exist_ok=True)

def load(p):
    return np.genfromtxt(p, delimiter=",", names=True, dtype=None, encoding="utf-8")

def segments(st, v, minlen=900, gap=5):
    ix = np.where(st == v)[0]
    if len(ix) == 0: return []
    br = np.where(np.diff(ix) > gap)[0]
    out = []; s = 0
    for b in br: out.append((ix[s], ix[b])); s = b + 1
    out.append((ix[s], ix[-1]))
    return [(x, y) for x, y in out if y - x > minlen]

def rise_1090(w, base):
    y = w - base; pk = y.max()
    if pk <= 0: return None
    i10 = np.argmax(y >= .10 * pk); i90 = np.argmax(y >= .90 * pk)
    return (i90 - i10) / 0.8 if i90 > i10 else None

plt.rcParams.update({"font.size": 9, "axes.grid": True, "grid.alpha": 0.25,
                     "axes.spines.top": False, "axes.spines.right": False,
                     "figure.facecolor": "w", "savefig.facecolor": "w"})

# =====================================================================
print("=== Fig A ===")
S  = load(os.path.join(D, r"v12\synth_floor.csv"))
st = np.asarray(S["d13"], int); raw = np.asarray(S["d12"], float)
SET = {0:55, 1:56, 2:57, 3:58, 4:60, 5:64, 6:72, 7:88}
gen = {}
for sdx, setv in SET.items():
    v = [r for x, y in segments(st, sdx)
         for r in [rise_1090(raw[x:y+1], np.median(raw[y-300:y]))] if r is not None]
    if v: gen[setv] = (np.median(v), np.std(v), len(v))
for k in sorted(gen):
    print("  commanded %2d -> measured %6.2f  sd %.3f samples (n=%d)" % (k, *gen[k]))

op = []
for f in sorted(glob.glob(os.path.join(G, "2026-08-28_FSR402_modC?_raw.csv"))):
    a = load(f); r = np.asarray(a["d2"], float)          # 該版位元流 raw 在 d2
    base = np.median(r[:600]); sd0 = r[:600].std()
    hi = r > base + max(8*sd0, 1500); ix = np.where(hi)[0]
    br = np.where(np.diff(ix) > 150)[0]
    for x, y in zip([ix[0]] + [ix[b+1] for b in br], [ix[b] for b in br] + [ix[-1]]):
        if y - x <= 15: continue
        rr = rise_1090(r[max(x-120,0):min(y+1, x+700)], base)
        if rr is not None: op.append(rr * SAMP_MS)
op = np.array(op)
op_med, op_sd = np.median(op), op.std(ddof=1)
k   = sorted(gen)
xs  = np.array(k, float) * SAMP_MS
res = (np.array([gen[v][0] for v in k]) - np.array(k, float)) * SAMP_MS
err = np.array([gen[v][1] for v in k]) * SAMP_MS
gsd = err.mean()
print("  operator: n=%d  median %.1f ms  sd %.1f ms" % (len(op), op_med, op_sd))
print("  generator repeat sd %.3f ms (%d of %d steps exactly 0.000)"
      % (gsd, sum(1 for v in k if gen[v][1] == 0), len(k)))
print("  RATIO %.0fx  (operator sd / one sample)" % (op_sd / SAMP_MS))

fig, ax = plt.subplots(1, 2, figsize=(9.6, 3.5))
ax[0].axhline(0, color="k", lw=0.8, zorder=1)
ax[0].axhspan(-SAMP_MS, SAMP_MS, color="C0", alpha=0.10, zorder=0,
              label="$\pm$1 sample of readout granularity")
ax[0].errorbar(np.array(k, float), res, yerr=err, fmt="o", ms=5.5, lw=0,
               elinewidth=1.4, capsize=3, color="C0", zorder=3)
ax[0].set_xlabel("commanded rise time (samples)")
ax[0].set_ylabel("measured $-$ commanded (ms)")
ax[0].set_ylim(-2.1, 2.9)
ax[0].set_xticks([55, 58, 64, 72, 88])
ax[0].set_title("(a) generator; the four leftmost points are consecutive samples", loc="left")
ax[0].text(0.97, 0.94, "repeat sd %.2f ms\n(%d of %d steps: sd = 0.000)"
           % (gsd, sum(1 for v in k if gen[v][1] == 0), len(k)),
           transform=ax[0].transAxes, ha="right", va="top", fontsize=8.2,
           bbox=dict(fc="w", ec="0.75", boxstyle="round,pad=0.35"))
ax[0].legend(frameon=False, fontsize=8, loc="lower right")

ax[1].hist(op, bins=np.arange(60, 240, 10), color="C1", alpha=0.85, edgecolor="w")
ax[1].axvspan(op_med - op_sd, op_med + op_sd, color="k", alpha=0.10, zorder=0,
              label="operator sd, $\\pm$%.1f ms" % op_sd)
ax[1].axvline(op_med, color="k", lw=1.1, ls="--", label="median %.0f ms" % op_med)
ax[1].axvspan(op_med - gsd, op_med + gsd, color="C0", zorder=4,
              label="generator sd, $\\pm$%.2f ms (to scale)" % gsd)
ax[1].set_xlabel("rise time (ms)"); ax[1].set_ylabel("presses")
ax[1].set_title("(b) one operator, %d presses, one instruction" % len(op), loc="left")
ax[1].legend(frameon=False, fontsize=7.8, loc="upper left")
plt.tight_layout()
plt.savefig(os.path.join(OUT, "fig_resolution_vs_operator.png"), dpi=220)
plt.close()

# =====================================================================
print("=== Fig B ===")
F  = load(os.path.join(D, r"v10\2026-08-30_v10_floor_subunit_raw.csv"))
st = np.asarray(F["d13"], int); m = np.asarray(F["mask"], int)
sb = np.asarray(F["status"], int); d2 = np.asarray(F["d2"], float)
PK = {25:41, 26:27, 27:20, 28:13, 29:10, 30:6, 31:3}     # 24 排除,見檔頭
pk_, rt_, n_, amp_, hits_ = [], [], [], [], []
for sdx, peak in sorted(PK.items(), key=lambda kv: kv[1]):
    sg = [(x, y) for x, y in segments(st, sdx) if not ((sb[x:y+1] >> 3) & 1).any()]
    if not sg: continue
    hit = sum(1 for x, y in sg if (m[x:x+260] != 0).any())
    amp = np.median([np.abs(d2[x:x+260] - np.median(d2[y-350:y-50])).max() for x, y in sg])
    pk_.append(peak); rt_.append(100.0*hit/len(sg)); n_.append(len(sg)); amp_.append(amp)
    hits_.append(hit)
qi  = np.concatenate([np.arange(y-350, y-50) for s in PK for x, y in segments(st, s)])
sd2 = d2[qi].std()
gain = np.median([a/p for a, p in zip(amp_, pk_) if p >= 27])   # 訊噪足夠的兩階
t5, t7 = 5*sd2/gain, 5*np.sqrt(2)*sd2/gain
for p, r, n, a in zip(pk_, rt_, n_, amp_):
    print("  peak %2d counts -> %5.1f %%  (n=%d, d2 amp %.0f)" % (p, r, n, a))
print("  d2 quiescent sd %.3f | raw->d2 gain %.2f | 5sig %.1f | 7.07sig %.1f counts"
      % (sd2, gain, t5, t7))

def wilson(h, n, z=1.96):
    if n == 0: return 0.0, 0.0
    p = h/n; d = 1 + z*z/n
    c = (p + z*z/(2*n))/d
    hw = z*np.sqrt(p*(1-p)/n + z*z/(4*n*n))/d
    return max(0.0, c-hw)*100, min(1.0, c+hw)*100
lo_, hi_ = zip(*[wilson(h, n) for h, n in zip(hits_, n_)])
lo_ = np.array(lo_); hi_ = np.array(hi_); rtA = np.array(rt_)

fig, ax = plt.subplots(figsize=(5.8, 3.8))
ax.axvspan(t5, t7, color="C2", alpha=0.12, zorder=0)
ax.errorbar(pk_, rtA, yerr=[rtA-lo_, hi_-rtA], fmt="o-", color="C0", ms=6.5,
            lw=1.8, elinewidth=1.1, capsize=3, zorder=3,
            label="measured, 95% Wilson interval")
ax.axvline(t5, color="C2", ls="--", lw=1.3, label="nominal $5\\sigma$ = %.0f counts" % t5)
ax.axvline(t7, color="C3", ls=":", lw=1.6,
           label="conservative seed $5\\sqrt{2}\\sigma$ = %.0f counts" % t7)
ax.axhline(50, color="0.65", lw=0.7, zorder=1)
ax.set_xscale("log"); ax.set_xticks(pk_); ax.set_xticklabels([str(p) for p in pk_])
ax.minorticks_off()
ax.set_xlabel("stimulus peak (ADC counts, set in registers)")
ax.set_ylabel("detected (%)"); ax.set_ylim(-8, 112)
ax.set_title("Detection floor (n = %d per amplitude)" % int(np.median(n_)), loc="left")
ax.legend(frameon=False, fontsize=8, loc="upper left")
plt.tight_layout()
plt.savefig(os.path.join(OUT, "fig_detection_floor.png"), dpi=220)
plt.close()

# =====================================================================
print("=== Fig C ===")
fig, ax = plt.subplots(2, 1, figsize=(7.4, 5.0), sharex=True)
for a, fn, ttl, col in ((ax[0], "sus2_v10.csv", "(a) guard without watchdog", "C3"),
                        (ax[1], "sus2_v12.csv", "(b) guard with watchdog", "C0")):
    dat = load(os.path.join(D, "v11dbg", fn))
    t = np.asarray(dat["t_s"], float); w = np.asarray(dat["d14"], int)
    mk = np.asarray(dat["mask"], int)
    a.plot(t, w, lw=1.0, color=col)
    a.set_ylabel("calibration\nwindow counter")
    a.set_ylim(-25, 555); a.set_yticks([0, 128, 256, 384, 512])

    wraps = int(np.sum(np.diff(w) < -100))
    ch = np.where(np.diff(w) != 0)[0]
    stall = np.diff(np.concatenate(([0], ch, [len(w)-1]))).max() / FS
    sub = ("%d windows completed in %.0f s   |   longest stall %.1f s   |   "
           "flag asserted %.0f%% of frames"
           % (wraps, t[-1], stall, 100*np.mean((mk & 4) != 0)))
    a.set_title(chr(10).join([ttl, sub]), loc="left", fontsize=8.6)
    print("  %s  windows %d  stall %.1f s  assert %.1f%%"
          % (fn, wraps, stall, 100*np.mean((mk & 4) != 0)))
ax[1].set_xlabel("time (s)")
fig.suptitle("Sustained contact: the noise estimator under a permanently asserting input",
             x=0.012, ha="left", fontsize=9.5)
plt.tight_layout(rect=[0, 0, 1, 0.955], h_pad=2.0)
plt.savefig(os.path.join(OUT, "fig_guard_lock.png"), dpi=220)
plt.close()
print("\n-> " + OUT)
