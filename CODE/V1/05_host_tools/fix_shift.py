"""fix_shift.py — 還原 ADS 讀取的隨機一位元減半，並換算成電阻。

    python fix_shift.py 原始檔.csv
    python fix_shift.py 原始檔.csv --rdiv 10.71 --out 修正後.csv

背景
────
`dual_orig.fs` 的 SPI 引擎分頻器是自由振盪的，CS 拉低時的相位決定一次交易裡
有 16 還是 17 個上升沿，於是約 44% 的讀取少取一位，值剛好變成一半。
24 MHz 邏輯分析儀確認：線上的資料是對的，減半發生在 FPGA 的擷取端，兩群
精確是 2:1 且分得很開。

還原原理
────────
減半只會讓值變小，所以**正確值一定是上面那群**。取滾動 70 百分位當基準
（正確樣本佔 56%，所以 70 百分位穩穩落在正確群裡），低於基準 0.72 倍的
樣本就乘 2。

限制 —— 一定要讀
────────────────
訊號在一個視窗內變化超過 1.5 倍時，「真的掉一半」和「位移」就分不出來。
腳本會標出這種視窗並拒絕保證那一段。**掃描的停留段（準靜態）可靠；
敲擊那種快速暫態不可靠**，後者要等 RTL 修好再測。
"""
import sys, argparse
import numpy as np
import pandas as pd

CH = ["ch0", "ch1", "ch2", "ch3"]
AIN = {"ch0": "AIN5(B)", "ch1": "AIN4(A)", "ch2": "AIN1(D)", "ch3": "AIN0(C)"}

ap = argparse.ArgumentParser(description="還原 ADS 一位元減半並換算電阻")
ap.add_argument("csv")
ap.add_argument("--rdiv", type=float, default=10.71,
                help="分壓電阻 kΩ（12k 並聯板上 100k = 10.71，預設）")
ap.add_argument("--win", type=int, default=301, help="滾動視窗樣本數（約 3 秒）")
ap.add_argument("--out", default=None, help="輸出 CSV，省略則只印報告")
ap.add_argument("--floor", type=float, default=200.0,
                help="低於此值的通道不做還原（訊號太接近零，比值無意義）")
ap.add_argument("--halved", action="store_true",
                help="確定性模式：每個樣本都減半了，全部乘 2。"
                     "dual_orig.fs 在目前接線下是這個狀態（100%% 單一群）。"
                     "用已知電阻確認過再開，開錯會讓所有電阻差兩倍。")
a = ap.parse_args()

d = pd.read_csv(a.csv)
for c in CH:
    d[c] = pd.to_numeric(d[c], errors="coerce")
dur = d.t_s.iloc[-1] - d.t_s.iloc[0]
print(f"{a.csv}")
print(f"  {len(d)} 列 / {dur:.1f}s = {len(d)/dur:.0f} 列/s   R_div = {a.rdiv} kΩ\n")

report = []
for c in CH:
    v = d[c].astype(float)
    if v.abs().median() < a.floor:
        report.append((c, 0, 0.0, 0, "訊號接近零，跳過還原"))
        d[c + "_fix"] = v
        continue

    if a.halved:
        # 確定性模式：整批都減半了，沒有「上面那群」可以當基準。
        over = int((v > 16383).sum())
        note = ""
        if over:
            note = (f"*** {over} 筆 >16383 — 乘 2 會溢位，這批不是單純的全體減半，"
                    "不要用 --halved")
        d[c + "_fix"] = v * 2
        report.append((c, len(v.dropna()), 100.0, over, note or "全體 ×2"))
        continue

    # 正確群在上面 -> 70 百分位是穩定的基準
    ref = v.rolling(a.win, center=True, min_periods=max(9, a.win // 6)).quantile(0.70)
    ref = ref.bfill().ffill()

    halved = v < 0.72 * ref
    fixed = v.where(~halved, v * 2)
    d[c + "_fix"] = fixed

    # 還原後仍離基準很遠的，是這個方法救不了的樣本
    resid = int(((fixed < 0.80 * ref) | (fixed > 1.25 * ref)).sum())

    # 模稜兩可的視窗：還原後訊號本身在視窗內就變化超過 1.5 倍
    hi = fixed.rolling(a.win, center=True, min_periods=9).max()
    lo = fixed.rolling(a.win, center=True, min_periods=9).min()
    ambig = int((hi > 1.5 * lo.clip(lower=1)).sum())

    note = ""
    if ambig:
        note = f"*** {100*ambig/len(v):.0f}% 的視窗內訊號變化 >1.5x — 那些段落不保證"
    report.append((c, int(halved.sum()), 100 * halved.mean(), resid, note))

print("通道        還原筆數    比例     殘留異常   備註")
for c, n, pct, resid, note in report:
    print(f"{c} {AIN[c]:<10} {n:6d}  {pct:5.1f}%   {resid:6d}   {note}")

if not a.halved:
    # 混合狀態下減半約佔 44%。明顯低於這個數，就分不出「沒有位移」和「全體減半」。
    silent = [c for c, n, pct, _, _ in report
              if pct < 25.0 and d[c].abs().median() >= a.floor]
    if silent:
        print(f"""
⚠  {', '.join(silent)} 一筆都沒還原。這有兩種可能，而這個方法分不出來：
     (a) 本來就沒有位移 —— 那很好，直接用
     (b) 整批都減半了 —— 那沒有「上面那群」可以當基準，本工具會靜靜地
         什麼都不做，然後給你兩倍的電阻
   dual_orig.fs 在目前接線下就是 (b)：100 kΩ 讀到 1604 而不是 3208。
   拿已知電阻量一次就能分辨；確認是 (b) 就加 --halved。""")

print("\n每個通道還原後的電阻（中位）")
for c in CH:
    f = d[c + "_fix"].dropna()
    med = float(np.median(f))
    if med < a.floor:
        print(f"  {c} {AIN[c]:<10} 中位 {med:8.0f} counts — 開路或未接，不換算")
    elif med >= 32767:
        print(f"  {c} {AIN[c]:<10} 中位 {med:8.0f} counts — 撞滿刻度，不換算")
    else:
        R = a.rdiv * (32767 / med - 1)
        print(f"  {c} {AIN[c]:<10} 中位 {med:8.0f} counts → {R:10.2f} kΩ")

print("""
方法的準確度（4290 列合成掃描，44.5% 減半，對照真值）
  各階中位數      13/13 正確
  殘差 99.6%      剛好 −1 count（減半丟掉的 LSB，約 0.004 kΩ，物理下限）
  真正分類錯誤    0.37%，全部落在階與階的跳變處
協議規定只取每階停留段的後段，那些跳變點本來就不會進入結果。""")

if a.out:
    d.to_csv(a.out, index=False)
    print(f"\n已寫出 {a.out}（原欄位保留，新增 ch0_fix..ch3_fix）")
else:
    print("\n（沒有 --out，只印報告，沒有寫檔）")
