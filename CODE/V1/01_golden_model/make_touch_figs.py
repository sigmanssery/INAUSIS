import sys, numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_repo\CODE\V1\01_golden_model")
from ttcgs_golden_model import dog_pipeline, make_kernels, SIGMAS
D = r"C:\Users\Admin\Desktop\INAUSIS\data\2026-08-18_FSR402_touch{}_raw.csv"

def load(tag):
    d = pd.read_csv(D.format(tag))
    v = pd.to_numeric(d.ch0, errors="coerce").ffill().bfill().to_numpy(float) * 2.0
    return v, d.t_s.to_numpy()

# ── 雜訊底：E 是 30 秒純基線 ──────────────────────────────────────────────
ve, te = load("E")
FS = len(te)/(te[-1]-te[0])
rn = dog_pipeline(ve)
NOISE = {k: float(np.std(rn[k])) for k in ("G_s3", "DoG_slow", "DoG_fast")}
print(f"fs={FS:.0f} SPS   sigma {SIGMAS} smp = {[round(s*1000/FS,1) for s in SIGMAS]} ms")
print(f"E 靜止基線 {len(ve)} 樣本: 中位 {np.median(ve):.0f} counts "
      f"= {10.855*(32767/np.median(ve)-1):.0f} kOhm,  sd {ve.std():.2f} counts")
print("雜訊底 (E):", {k: round(v,2) for k,v in NOISE.items()})

v, t = load("5")
res = dog_pipeline(v)
MS = [s*1000/FS for s in SIGMAS]
A, B = 74.6, 86.2
k = (t>=A)&(t<=B); tt = t[k]-A; sig = v[k]
sm = pd.Series(sig).rolling(15, center=True, min_periods=3).median().to_numpy()
pk = np.nanmax(sm); on_i = int(np.argmax(sm > .5*pk))
rel_i = len(sm) - int(np.argmax(sm[::-1] > .5*pk)) - 1
# adjustment = 按住期間 DoG_fast 活躍的區段（用特徵自己定義階段）
df = np.abs(res["DoG_fast"][k])
env = pd.Series(df).rolling(int(.35*FS), center=True, min_periods=5).mean().to_numpy()
hold = slice(on_i+int(.7*FS), rel_i-int(.30*FS))
base_env = np.median(env[hold])
act = np.where(env[hold] > 6*base_env)[0]
if len(act):
    adj = (tt[hold.start+act[0]], tt[hold.start+act[-1]])
else:
    adj = (tt[rel_i]-2.0, tt[rel_i]-.3)
print(f"adjustment 偵測: {adj[0]:.2f}~{adj[1]:.2f}s  (DoG_fast 包絡 > 6x 按住期中位)")

INK="#1a202c"
fig, ax = plt.subplots(4,1, figsize=(9.8,8.8), sharex=True,
                       gridspec_kw={"height_ratios":[1.25,1,1,1], "hspace":.15})
ax[0].plot(tt, sig, lw=.7, color=INK); ax[0].set_ylabel("FSR (counts)")
ax[1].plot(tt, res["G_s3"][k], lw=1.4, color="#2b6cb0")
ax[1].set_ylabel(f"G$_{{\sigma_3}}$\n{SIGMAS[2]:.0f} smp = {MS[2]:.0f} ms")
ax[2].plot(tt, res["DoG_slow"][k], lw=1.1, color="#2f855a")
ax[2].set_ylabel(f"DoG$_{{slow}}$\n{MS[1]:.0f}$-${MS[2]:.0f} ms")
ax[3].plot(tt, res["DoG_fast"][k], lw=1.0, color="#c05621")
ax[3].set_ylabel(f"DoG$_{{fast}}$\n{MS[0]:.1f}$-${MS[1]:.0f} ms")
ax[3].set_xlabel("time (s)")
for a in ax: a.axhline(0, lw=.5, color="#bbb", zorder=0); a.margins(x=.01)
ph=[(tt[on_i]-.15, tt[on_i]+.45, "touch onset","#c05621", 1.15),
    (tt[on_i]+.5, adj[0]-.05, "stable","#2b6cb0", 1.15),
    (adj[0], adj[1], "adjustment","#2f855a", 1.15),
    (tt[rel_i]-.20, tt[rel_i]+.55, "release","#9b2c2c", 1.015)]
y0,y1 = ax[0].get_ylim(); ax[0].set_ylim(y0, y1*1.26)
for a0,a1,lab,col,hy in ph:
    for a in ax: a.axvspan(a0,a1,color=col,alpha=.10,lw=0)
    ax[0].annotate(lab, ((a0+a1)/2, y1*hy), ha="center", va="top",
                   fontsize=9, color=col, fontweight="bold")
ax[0].set_title(f"Fig. 4   Causal DoG response to touch and release  "
                f"(FSR402, {FS:.0f} SPS)", fontsize=11)
plt.savefig("fig4.png", dpi=150, bbox_inches="tight"); plt.close()

# 偵測統計：以 E 的雜訊底算 z
print("\n特徵      靜止 |z|max (E)    此事件 |z|max    倍率")
for key in ("DoG_fast","DoG_slow","G_s3"):
    zr = np.abs(rn[key]).max()/NOISE[key]
    ze = np.abs(res[key][k]).max()/NOISE[key]
    print(f"{key:<10}{zr:>12.1f}{ze:>17.0f}{ze/zr:>9.0f}x")
print("written fig4.png")

# ── Fig 5 ────────────────────────────────────────────────────────────────
ker = make_kernels()
w1, w2 = int(round(6*SIGMAS[0])), int(round(6*SIGMAS[1]))
ma1 = np.convolve(v, np.ones(w1)/w1)[:len(v)]
ma2 = np.convolve(v, np.ones(w2)/w2)[:len(v)]
mad = ma1 - ma2
z0 = A + tt[on_i] - 0.03
zk = (t >= z0) & (t <= z0+0.40)
fig, ax = plt.subplots(1, 2, figsize=(12.6, 4.6))
a0 = ax[0]
dg = res["DoG_fast"][zk]/np.abs(res["DoG_fast"][zk]).max()
mm = mad[zk]/np.abs(mad[zk]).max()
ms_ = (t[zk]-z0)*1000
a0.plot(ms_, dg, lw=1.5, color="#c05621",
        label="causal DoG$_{{fast}}$ ({:.1f}$-${:.0f} ms)".format(MS[0], MS[1]))
a0.plot(ms_, mm, lw=1.2, color="#718096", ls="--",
        label="moving-average difference ({}$-${} smp)".format(w1, w2))
a0.axhline(0, lw=.5, color="#bbb")
late = ms_ > 120
a0.annotate("MA still ringing", (250, mm[late].max()), xytext=(0, 28),
            textcoords="offset points", fontsize=8.5, color="#4a5568", ha="center",
            arrowprops=dict(arrowstyle="->", color="#718096", lw=.9))
a0.set_xlabel("time from touch onset (ms)"); a0.set_ylabel("normalised response")
a0.set_title("touch-onset rising edge", fontsize=10.5)
a0.legend(fontsize=8.5); a0.grid(alpha=.25)
print("after 120 ms:  MA rms {:.3f}   DoG rms {:.3f}   -> {:.1f}x quieter".format(
    np.sqrt((mm[late]**2).mean()), np.sqrt((dg[late]**2).mean()),
    np.sqrt((mm[late]**2).mean())/max(np.sqrt((dg[late]**2).mean()), 1e-9)))

nfft = 16384; f = np.fft.rfftfreq(nfft, 1/FS)
Hd = np.abs(np.fft.rfft(ker[0]-ker[1], nfft)); Hd /= Hd.max()
Hm = np.abs(np.fft.rfft(np.ones(w1)/w1, nfft) - np.fft.rfft(np.ones(w2)/w2, nfft))
Hm /= Hm.max()
a1 = ax[1]
a1.semilogx(f[1:], 20*np.log10(Hm[1:]+1e-12), lw=1.2, color="#718096", ls="--",
            label="moving-average difference")
a1.semilogx(f[1:], 20*np.log10(Hd[1:]+1e-12), lw=1.5, color="#c05621", label="causal DoG")
a1.set_ylim(-80, 5); a1.set_xlim(0.3, FS/2)
a1.set_xlabel("frequency (Hz)"); a1.set_ylabel("magnitude (dB)")
a1.set_title("frequency response", fontsize=10.5)
a1.legend(fontsize=8.5, loc="lower left"); a1.grid(alpha=.3, which="both")
sd_ = 20*np.log10(Hd[1:]+1e-12)
a1.annotate("MA: nulls and sidelobes", (150, -46), xytext=(-4, -30),
            textcoords="offset points", fontsize=8.5, color="#4a5568", ha="center",
            arrowprops=dict(arrowstyle="->", color="#718096", lw=.9))
a1.annotate("DoG: monotonic, no ripple", (150, sd_[np.argmin(abs(f[1:]-150))]),
            xytext=(-4, 26), textcoords="offset points", fontsize=8.5,
            color="#c05621", ha="center",
            arrowprops=dict(arrowstyle="->", color="#c05621", lw=.9))
fig.suptitle("Fig. 5   Causal DoG versus moving-average difference on the measured FSR signal",
             fontsize=11, y=1.02)
plt.savefig("fig5.png", dpi=150, bbox_inches="tight"); plt.close()
print("written fig5.png")
