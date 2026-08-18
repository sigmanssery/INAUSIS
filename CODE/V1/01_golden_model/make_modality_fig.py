import sys, numpy as np, pandas as pd
import matplotlib; matplotlib.use("Agg")
import matplotlib.pyplot as plt
sys.path.insert(0, r"C:\Users\Admin\Desktop\INAUSIS\INAUSIS_repo\CODE\V1\01_golden_model")
from ttcgs_golden_model import dog_pipeline
D=r"C:\Users\Admin\Desktop\INAUSIS\data\2026-08-18_FSR402_touch{}_raw.csv"
NAME={"A":"rapid light taps","B":"slow press","C":"rhythmic press modulation",
      "D":"single press-release","E":"light stroking","F":"fingernail scratch",
      "G":"rapid rhythmic press, held"}
COL={"A":"#c05621","B":"#2b6cb0","C":"#2f855a","D":"#6b46c1",
     "E":"#b83280","F":"#b7791f","G":"#2c7a7b"}

dd=pd.read_csv(D.format("E")); ve=pd.to_numeric(dd.ch0,errors="coerce").ffill().bfill().to_numpy(float)*2
te=dd.t_s.to_numpy(); FS=len(te)/(te[-1]-te[0]); re_=dog_pipeline(ve)
q=(te>1.0)&((te<9.5)|(te>25.5))
N={k:float(np.std(re_[k][q])) for k in ("G_s3","DoG_slow","DoG_fast")}

fig = plt.figure(figsize=(13.5, 8.6))
gs = fig.add_gridspec(7, 2, width_ratios=[1.75, 1], hspace=.35, wspace=.22)
axS = fig.add_subplot(gs[:, 1])
stat = []
for i, tag in enumerate("ABCDEFG"):
    d = pd.read_csv(D.format(tag))
    v = pd.to_numeric(d.ch0, errors="coerce").ffill().bfill().to_numpy(float)*2
    t = d.t_s.to_numpy(); r = dog_pipeline(v); m = t > 1.0
    vm, tm = v[m], t[m]
    zf = np.abs(r["DoG_fast"][m]).max()/N["DoG_fast"]
    zs = np.abs(r["DoG_slow"][m]).max()/N["DoG_slow"]
    pp = vm.max()-vm.min()
    stat.append((tag, 100*pp/32767, zf/zs, zf))
    # 取活動最密的 4 秒
    act = pd.Series(np.abs(np.diff(vm, prepend=vm[0]))).rolling(int(4*FS),
            center=True, min_periods=10).sum().to_numpy()
    c = int(np.nanargmax(act)); a = max(c-int(2*FS), 0); b = min(a+int(4*FS), len(vm)-1)
    seg = vm[a:b]; ts = tm[a:b]-tm[a]
    ax = fig.add_subplot(gs[i, 0])
    ax.plot(ts, (seg-seg.min())/max(seg.max()-seg.min(), 1), lw=.8, color=COL[tag])
    ax.set_ylim(-.12, 1.25); ax.set_yticks([])
    ax.set_ylabel(tag, rotation=0, ha="right", va="center", fontsize=11, fontweight="bold")
    ax.text(.012, .97, f"{NAME[tag]}   —   {100*pp/32767:.1f}% FS,  "
            f"fast/slow {zf/zs:.2f}", transform=ax.transAxes, va="top",
            fontsize=8.6, color=COL[tag])
    for s in ("top","right"): ax.spines[s].set_visible(False)
    if i < 6: ax.set_xticklabels([])
    else: ax.set_xlabel("time (s)   — each trace normalised to its own range")

for tag, ppf, ratio, zf in stat:
    axS.scatter(ratio, ppf, s=130, color=COL[tag], zorder=3, edgecolor="w", lw=1.2)
    axS.annotate(tag, (ratio, ppf), xytext=(9, -4), textcoords="offset points",
                 fontsize=10, fontweight="bold", color=COL[tag])
axS.set_yscale("log"); axS.set_xlim(0.10, 1.12)
dC = [x for x in stat if x[0]=="C"][0]; dG = [x for x in stat if x[0]=="G"][0]
axS.plot([dC[2], dG[2]], [dC[1], dG[1]], color="#4a5568", lw=1.1, ls=":", zorder=1)
lab1 = "same amplitude (96.1 / 94.5% FS)," + chr(10) + "band ratio differs 2.3x"
axS.annotate(lab1, ((dC[2]+dG[2])/2, dC[1]*1.6), ha="center", fontsize=8.8, color="#4a5568")
lab2 = "light stroking: 0.4% FS," + chr(10) + "still 35 sigma on DoG_fast"
axS.annotate(lab2, (0.96, 0.55), ha="center", fontsize=8.8, color="#b83280")
axS.set_xlabel("peak |z| ratio,  DoG$_{fast}$ / DoG$_{slow}$")
axS.set_ylabel("peak-to-peak amplitude (% of full scale)")
axS.set_title("band ratio varies with contact type at matched amplitude", fontsize=10.5)
axS.grid(alpha=.3, which="both")
fig.suptitle("Fig. 6   Seven touch modalities through the causal DoG chain "
             f"(FSR402, {FS:.0f} SPS)", fontsize=12, y=.965)
plt.savefig("fig6.png", dpi=150, bbox_inches="tight")
print("written fig6.png")
for tag, ppf, ratio, zf in stat:
    print(f"  {tag} {NAME[tag]:<30} {ppf:5.1f}% FS   fast/slow {ratio:.2f}   peak|z|fast {zf:.0f}")
