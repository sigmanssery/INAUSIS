"""check_stream.py — 快速體檢 top_dual 的 UART 串流，不寫檔。

    python check_stream.py            # 自動找埠，讀 5 秒
    python check_stream.py 8          # 讀 8 秒
    python check_stream.py 5 COM7     # 指定埠

會等埠出現（拔插 USB 後要幾秒重新列舉），所以拔插完立刻執行也沒關係。
輸出：各行別的計數、CHIP_ID 分布、RP/L 的中位數與 sd、STATUS 分布。
判讀：ID 有 D4 = LDC 在 SPI 上活著；出現 FF = 掉線；ID 完全沒有 = 跑的不是
含 CHIP_ID 的那版 bitstream（SRAM 燒錄斷電就會退回 flash 裡的舊版）。
"""
import sys, time, re, collections
import serial
from serial.tools import list_ports

secs = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
want = sys.argv[2] if len(sys.argv) > 2 else None

# 等埠出現，最多 20 秒
port = None
for _ in range(40):
    names = [p.device for p in list_ports.comports()]
    if want and want in names:
        port = want; break
    if not want and names:
        port = sorted(names, key=lambda s: int(re.sub(r"\D", "", s) or 0))[-1]; break
    time.sleep(0.5)
if port is None:
    print("找不到 COM 埠 — FPGA 插了嗎？"); sys.exit(1)
print(f"讀取 {port} @921600，{secs:.0f} 秒 ...")

sp = serial.Serial(port, 921600, timeout=0.05)
t0 = time.time(); buf = b""
while time.time() - t0 < secs:
    buf += sp.read(8192)
sp.close()

pat = re.compile(rb"\s*(ID|ST|RP|L|CH[0-3])\s*:\s*([0-9A-Fa-f]{4})")
vals = collections.defaultdict(list)
lines = 0
for ln in buf.split(b"\n"):
    m = pat.match(ln.strip())
    if m:
        vals[m.group(1).decode()].append(int(m.group(2), 16)); lines += 1

bad = sum(1 for c in buf if not (32 <= c < 127 or c in (10, 13)))
print(f"{len(buf)} bytes, {lines} 筆已解析, 非可列印 {bad} ({100*bad/max(len(buf),1):.2f}%)\n")
if not lines:
    print("*** 解析不到任何資料行 — 鮑率或 bitstream 不對"); sys.exit(1)

# ADS 的轉換結果是 16-bit 有號的；上面照原樣存無號，這裡只在顯示 CH 時轉補數。
# ID/ST/RP/L 維持無號（它們本來就是無號的暫存器內容）。
def s16(v):
    return v - 65536 if v >= 32768 else v

def shift_report(sv):
    """一位元位移偵測。以最常見值為基準，數有多少樣本落在它的一半或兩倍。

    範圍與相異值個數看不出位移 —— 穩定的固定電阻本來就只有幾個相異值，
    而位移群跟正常群會同時落在範圍裡。這個檢查是唯一直接的判準。
    """
    c = collections.Counter(sv)
    # 基準一律取「上面那群」。物理機制是漏取一位 -> 值只會變小，所以正確值
    # 永遠是大的那個。用眾數當基準的話，兩群接近五五分時標籤會在「減半」和
    # 「加倍」之間翻轉，同一件事看起來像兩種故障。
    top = [v for v, _ in c.most_common(6)]
    ref = max(top, key=lambda v: (abs(v), c[v]))
    if abs(ref) < 500:                     # 訊號本身接近 0 時，比值沒有意義
        return None, ""
    tol = 0.03
    half = sum(n for v, n in c.items() if abs(v - ref / 2) < tol * abs(ref))
    dbl  = sum(n for v, n in c.items() if abs(v - ref * 2) < tol * abs(ref) * 2)
    tot  = len(sv)
    # 位移是雙峰的：ref 和 ref/2 之間應該是空的。連續的雜訊會把中間填滿，
    # 那不是位移。沒有這道檢查，±170 的雜訊會被誤報成「減半 2.7%」。
    lo, hi = sorted((0.60 * ref, 0.90 * ref))
    gap = sum(n for v, n in c.items() if lo < v < hi)
    if gap >= max(half, 1):
        return ref, "  位移 0 ✓（分布連續，非雙峰）"
    if not (half or dbl):
        return ref, "  位移 0 ✓"
    parts = []
    if half: parts.append(f"減半 {half} ({100*half/tot:.1f}%)")
    if dbl:  parts.append(f"加倍 {dbl} ({100*dbl/tot:.1f}%)")
    return ref, "  *** 位元位移: " + " / ".join(parts)

for k in ("CH0", "CH1", "CH2", "CH3"):
    if vals[k]:
        sv = [s16(v) for v in vals[k]]
        n_uniq = len(set(sv))
        frozen = "   *** 只有一個值 — ADC 沒在轉換" if n_uniq == 1 else ""
        rail   = sum(1 for v in sv if abs(v) > 32000)
        rtxt   = f"   撞軌 {rail} ({100*rail/len(sv):.1f}%)" if rail else ""
        print(f"{k}: n={len(sv)}  範圍 {min(sv)}~{max(sv)}  相異 {n_uniq}{rtxt}{frozen}")
        top = collections.Counter(sv).most_common(6)
        print("      最常見 " + "  ".join(f"{v}x{n}" for v, n in top))
        ref, msg = shift_report(sv)
        if msg:
            print("     " + msg)

print("\n  『範圍』和『相異值』看不出位元位移 —— 要看上面那行『位移』。")
print("  接固定電阻時相異值本來就少（訊號穩定），那不是故障。")
print("  真正的故障樣子：單一值 = 驅動停擺；位移 > 0 = bitstream 不對或時序邊緣。")

def stat(name, a, ref=""):
    if not a:
        print(f"{name}: (無)"); return
    import statistics as st
    print(f"{name}: n={len(a):5d}  中位={st.median(a):8.1f}  sd={st.pstdev(a):7.2f}  "
          f"min={min(a):6d}  max={max(a):6d}{ref}")

print()
stat("RP", vals["RP"])
stat("L ", vals["L"], "     健康時 sd < 1")

for name, key, good in (("CHIP_ID", "ID", "D4"), ("STATUS", "ST", None)):
    c = collections.Counter(f"{v & 0xFF:02X}" for v in vals[key])
    if not c:
        print(f"\n{name}: 沒有這種行 ***"
              + ("  <- 跑的不是含 CHIP_ID 的 bitstream" if key == "ID" else ""))
        continue
    print(f"\n{name}: " + "  ".join(f"{k}x{v}" for k, v in c.most_common(6)))
    if key == "ID":
        ff = c.get("FF", 0)
        print("  0xFF（掉線）: " + (f"{ff} *** LDC 曾離開匯流排" if ff else "0 ✓"))
        print(f"  0xD4（正常回應）: {c.get('D4',0)}"
              + ("" if c.get("D4") else "  *** 一次都沒有，SPI 沒在通"))
    else:
        st_ = sum(v for k, v in c.items() if int(k, 16) & 0x80 and k != "FF")
        print(f"  NO_SENSOR_OSC（合法 STATUS，真停振）: {st_}"
              f"   速率 {st_/secs:.2f} 次/秒")
