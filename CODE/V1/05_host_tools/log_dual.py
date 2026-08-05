#!/usr/bin/env python3
# log_dual.py — capture the top_dual UART stream to CSV for offline analysis.
#
# Records every sample as one row: t_s, ch0..ch3, rp, l  (decimal, plus the raw
# hex kept for RP/L so nothing is lost). Prints a live one-line status so you can
# see the event happening while it records.
#
# Usage:
#   python log_dual.py --port COM6 --out ..\data\2026-07-03_MRE_press_raw.csv
#   python log_dual.py --port COM6 --secs 30          (auto-stop after 30 s)
#   Ctrl+C to stop early — the file is flushed as it goes, nothing is lost.
#
# Marking events while recording: press ENTER to stamp a marker in the `mark`
# column (e.g. "press", "release"). Type text then ENTER to label it.
#
# Notes on the dual stream: ADS (CHx) and LDC (RP/L) arrive as separate lines in
# a ~6-line burst. A row is emitted per burst, carrying the latest of each.
import argparse, os, re, sys, time, threading, queue, traceback

import serial


def to_s16(v):
    return v - 65536 if v >= 32768 else v


def main():
    ap = argparse.ArgumentParser(description="log top_dual UART to CSV")
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--out", default=None, help="CSV path (default: dual_log_<timestamp>.csv)")
    ap.add_argument("--secs", type=float, default=0, help="auto-stop after N seconds (0 = until Ctrl+C)")
    # Windows 主控台預設開啟 QuickEdit：使用者在視窗裡點一下（或選到文字），下一次
    # 寫 stdout 就會整個阻塞，錄製隨之停住而且看起來像當機。2026-08-04 兩次 10 小時
    # 錄製就是這樣死在 70 分和 87 分（資料到最後一列都健康，行程被主控台凍住）。
    # --quiet 完全不碰 stdout，改把狀態每 2 秒覆寫到 <out>.status。
    ap.add_argument("--quiet", action="store_true",
                    help="no stdout during capture; status goes to <out>.status instead")
    ap.add_argument("--rail", type=float, default=20000.0,
                    help="flag |CHx|>rail as a bad ADS read (kept in CSV, column bad_ads)")
    a = ap.parse_args()

    out = a.out or time.strftime("dual_log_%Y-%m-%d_%H%M%S.csv")
    parent = os.path.dirname(os.path.abspath(out))
    os.makedirs(parent, exist_ok=True)      # create the target dir if it's new
    sp = serial.Serial(a.port, a.baud, timeout=0.05)

    pat_ch = re.compile(rb'CH([0-3]):\s*([0-9A-Fa-f]{4})')
    pat_rp = re.compile(rb'RP\s*:\s*([0-9A-Fa-f]{4})')
    pat_l = re.compile(rb'\bL\s+:\s*([0-9A-Fa-f]{4})')
    # LDC STATUS(0x20), sticky since the previous ST line. bit7 NO_SENSOR_OSC =
    # the tank stopped oscillating (RP fell below RP_SET:RP_MIN); bit0 POR_READ.
    pat_st = re.compile(rb'ST\s*:\s*([0-9A-Fa-f]{4})')
    # CHIP_ID(0x3F), re-read every LDC loop. D4 = the LDC is answering on SPI.
    pat_id = re.compile(rb'ID\s*:\s*([0-9A-Fa-f]{4})')

    # ENTER-to-mark, on a background thread so it never blocks the capture
    marks = queue.Queue()

    def reader():
        for line in sys.stdin:
            marks.put(line.strip() or "mark")
    threading.Thread(target=reader, daemon=True).start()

    ch = [None] * 4
    seen = [False] * 4
    any_ch = [False]          # has this stream ever carried CHx lines?
    rp = l = st = cid = None
    id_ff  = [0]              # CHIP_ID == 0xFF -> MISO floating, LDC off the bus
    id_odd = [0]              # CHIP_ID neither 0xD4 nor 0x00/0xFF (unexpected)
    osc_stalls = [0]          # ST lines with NO_SENSOR_OSC set, since start
    dead_link  = [0]          # ST lines reading 0xFF = MISO floating, LDC off the bus.
                              # 0xFF sets NO_SENSOR_OSC too, so it fakes a tank stall.
    rows = 0
    t0 = time.time()
    status_path = out + ".status"
    last_status = [0.0]

    print(f"[{a.port} @{a.baud}] -> {out}")
    print("recording... type a label + ENTER to mark an event (e.g. 'press'), Ctrl+C to stop\n")

    with open(out, "w", encoding="utf-8", newline="") as f:
        f.write("t_s,ch0,ch1,ch2,ch3,rp,l,rp_hex,l_hex,bad_ads,status,no_osc,chip_id,mark\n")
        try:
            while True:
                if a.secs and (time.time() - t0) >= a.secs:
                    break
                raw = sp.readline()
                if not raw:
                    continue

                emit = False
                m = pat_ch.search(raw)
                if m:
                    i = int(m.group(1))
                    ch[i] = to_s16(int(m.group(2), 16))
                    seen[i] = True
                    any_ch[0] = True
                    # one row per full CH0-3 set (dual stream / ADS-only bitstream)
                    if all(seen):
                        seen = [False] * 4
                        emit = True
                else:
                    m = pat_rp.search(raw)
                    if m:
                        rp = int(m.group(1), 16)
                    else:
                        m = pat_id.search(raw)
                        if m:
                            cid = int(m.group(1), 16) & 0xFF
                            # 0x00 = a read that returned nothing; benign here (the
                            # per-loop CHIP_ID re-read fails on alternate loops but
                            # RP/L stay clean). 0xFF = MISO floating, i.e. the LDC is
                            # off the bus — that is the one worth counting.
                            if cid == 0xFF:
                                id_ff[0] += 1
                            elif cid != 0xD4:
                                id_odd[0] += 1
                            continue
                        m = pat_st.search(raw)
                        if m:
                            st = int(m.group(1), 16) & 0xFF
                            if st & 0x80:
                                osc_stalls[0] += 1
                            if st == 0xFF:
                                dead_link[0] += 1
                        else:
                            m = pat_l.search(raw)
                            if m:
                                l = int(m.group(1), 16)
                                # LDC-only fast stream: no CHx will ever arrive, so
                                # pace rows off L or nothing would ever be written
                                if not any_ch[0]:
                                    emit = True
                if not emit:
                    continue
                t = time.time() - t0
                mark = ""
                while not marks.empty():
                    mark = marks.get()
                bad = int(any(c is not None and abs(c) > a.rail for c in ch))
                cells = [f"{c}" if c is not None else "" for c in ch]
                rp_s = "" if rp is None else str(rp)
                l_s = "" if l is None else str(l)
                rp_h = "" if rp is None else f"{rp:04X}"
                l_h = "" if l is None else f"{l:04X}"
                st_s = "" if st is None else f"{st:02X}"
                no_osc = 0 if st is None else int(bool(st & 0x80))
                id_s = "" if cid is None else f"{cid:02X}"
                f.write(f"{t:.4f},{','.join(cells)},{rp_s},{l_s},"
                        f"{rp_h},{l_h},{bad},{st_s},{no_osc},{id_s},{mark}\n")
                f.flush()
                rows += 1
                if rows % 20 == 0 or mark:
                    ldc_s = ("LDC --" if rp is None else
                             f"RP={rp:5d} (0x{rp:04X})  L={l:4d} (0x{l:04X})")
                    line = (f" t={t:7.2f}s  rows={rows:6d}  {ldc_s}  "
                            f"ID={id_s or '--'} ST={st_s or '--'} "
                            f"idFF={id_ff[0]:4d} osc={osc_stalls[0]:5d}  "
                            f"bad={'Y' if bad else '.'}  {mark}")
                    if a.quiet:
                        if time.time() - last_status[0] > 2.0:
                            last_status[0] = time.time()
                            try:
                                with open(status_path, "w", encoding="utf-8") as sf:
                                    sf.write(line + "\n")
                            except OSError:
                                pass
                    else:
                        print("\r" + line, end="", flush=True)
        except KeyboardInterrupt:
            why = "KeyboardInterrupt (Ctrl+C / 視窗關閉)"
        except BaseException:
            # 任何其他例外都要留下證據。長時間錄製在 --quiet 下沒有畫面輸出，
            # 崩掉時 traceback 可能隨視窗一起消失，事後就完全查不出原因
            # （2026-08-03/04/05 三次 10 小時錄製都只知道「停了」）。
            why = "例外:\n" + traceback.format_exc()
        else:
            why = f"正常結束(--secs {a.secs:g} 到期)" if a.secs else "正常結束"

    sp.close()
    # 收尾一律寫進 <out>.status 和 <out>.log，不依賴主控台還在
    summary = (f"結束於 t={time.time()-t0:.1f}s, rows={rows}\n"
               f"原因: {why}\n"
               f"CHIP_ID 0xFF: {id_ff[0]}   停振: {osc_stalls[0]}   死線 STATUS 0xFF: {dead_link[0]}\n")
    for path in (status_path, out + ".log"):
        try:
            with open(path, "a" if path.endswith(".log") else "w", encoding="utf-8") as sf:
                sf.write(("\n" if path.endswith(".log") else "") + summary)
        except OSError:
            pass
    print("\n\n" + summary)
    print(f"done: {rows} rows -> {out}")
    if id_ff[0]:
        print(f"*** CHIP_ID read 0xFF in {id_ff[0]} loops — MISO was floating, i.e. the "
              f"LDC dropped off the SPI bus. RP/L from those samples are meaningless.")
    else:
        print("CHIP_ID never read 0xFF — the LDC stayed on the bus the whole time.")
    if id_odd[0]:
        print(f"    ({id_odd[0]} loops read a CHIP_ID that was neither D4, 00 nor FF — "
              f"worth a look, that is not a pattern we have seen.)")
    if dead_link[0]:
        print(f"*** STATUS read 0xFF in {dead_link[0]} intervals — that is not a device "
              f"report, it is a FLOATING MISO: the LDC dropped off the SPI bus (lost "
              f"power / link died). Screen the CSV for 0xFF before analysing anything.")
        if osc_stalls[0] > dead_link[0]:
            print(f"    ({osc_stalls[0] - dead_link[0]} further intervals had "
                  f"NO_SENSOR_OSC with a valid STATUS — those are real tank stalls.)")
    elif osc_stalls[0]:
        print(f"*** NO_SENSOR_OSC asserted in {osc_stalls[0]} intervals with a valid "
              f"STATUS — a genuine tank stall. RP may be dropping below RP_SET:RP_MIN.")
    else:
        print("NO_SENSOR_OSC never asserted — the tank kept oscillating throughout.")
    if rows:
        print("next: plot/quantify with your usual tools; RP/L are raw counts "
              "(work in Δ vs the no-target baseline, the absolute level shifts "
              "between setups).")


if __name__ == "__main__":
    main()
