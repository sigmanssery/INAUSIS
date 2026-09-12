# -*- coding: utf-8 -*-
"""log_frames.py — capture the TTCGS frame stream from the bring-up UART mirror.

The mirror (frame_uart_mirror.v) sends, per frame:

    0xAA 0xA5 <len> <len payload bytes>

and the payload is the 51-byte frame that frame_packer.v built:

    0-1    0xAA 0x55 preamble marker
    2-5    timestamp, 32-bit big-endian
    6-41   18 dimensions x 2 bytes, big-endian signed
    42-44  18-bit attention mask   (lo8, mid8, {6'b0, hi2})
    45-47  18-bit dead-channel map (same layout)
    48     status:
             bit0  constant 1 (frame marker; a status of 0 means a parse error)
             bit1  slide flag
             bit2  contact flag
             bit3  uncal   -- 1 = at least one dim still calibrating or retrying
             bit4  ldc_alive     -- CHIP_ID reads 0xD4 AND data seen within 100 ms
             bit5  ldc_err   -- 1 = LDC CHIP_ID read back something other than
                                0xD4.  With bit4 this separates a stopped driver
                                (alive 0, err 0) from a chip answering wrongly
                                (alive 0, err 1).  Was ldc_init_done before
                                2026-09-03; that signal never settles unattached.
             bit6  ads_init_done
             bit7  ads_err
           Bits 7:4 were hard-zero before 2026-09-02. A capture whose status
           never has any of them set is either from an older bitstream or from
           a genuinely dead front end -- check_health.py tells them apart.
    49-50  CRC-16-CCITT over bytes 0..48, big-endian

CRC is the 0xFFFF-init, poly 0x1021, MSB-first, no-reflection, no-final-XOR
variant, matching crc16_ccitt.v.

Every frame is CRC-checked; only frames that pass are written. The counts of
bad-CRC and resync events are reported, because a healthy link should show
zero of both.
"""
import argparse, os, sys, time, threading
import serial
try:
    import winsound
except ImportError:
    winsound = None

SYNC0, SYNC1 = 0xAA, 0xA5

def crc16(data):
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc

def s16(v):
    return v - 0x10000 if v & 0x8000 else v

def decode(p):
    ts   = int.from_bytes(p[2:6], "big")
    dims = [s16(int.from_bytes(p[6+2*i:8+2*i], "big")) for i in range(18)]
    mask = p[42] | (p[43] << 8) | ((p[44] & 0x03) << 16)
    dead = p[45] | (p[46] << 8) | ((p[47] & 0x03) << 16)
    return ts, dims, mask, dead, p[48]

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True)
    ap.add_argument("--baud", type=int, default=921600)
    ap.add_argument("--secs", type=float, default=0, help="0 = until Ctrl+C")
    ap.add_argument("--out", default="frames.csv")
    ap.add_argument("--cue-period", type=float, default=0,
                    help="seconds between press cues; 0 = no cue")
    ap.add_argument("--cue-hold", type=float, default=0,
                    help="seconds between the press tone and the release tone; "
                         "0 = press tone only (for gestures held throughout)")
    ap.add_argument("--cue-leadin", type=int, default=1,
                    help="low 'ready' ticks before the first press cue; they use "
                         "the same period and are logged as cue=3")
    ap.add_argument("--cue-after", type=float, default=5.0,
                    help="delay before the first cue, leaving a clean rest window")
    a = ap.parse_args()

    ser = serial.Serial(a.port, a.baud, timeout=0.2)
    # The board streams continuously, so the driver holds frames from before this
    # run started.  Without this the first ~150 rows are the tail of the PREVIOUS
    # capture -- stale presses and all -- glued on with a timestamp discontinuity.
    # Flush, let the FTDI latency timer drain what was already in flight, flush again.
    ser.reset_input_buffer()
    time.sleep(0.15)
    ser.reset_input_buffer()
    d = os.path.dirname(os.path.abspath(a.out))
    if not os.path.isdir(d):
        os.makedirs(d, exist_ok=True)
    f = open(a.out, "w", encoding="utf-8")
    f.write("t_s,ts," + ",".join("d%d" % i for i in range(18)) + ",mask,dead,status,cue\n")

    buf = bytearray()
    # reset_input_buffer alone still let ~74 stale frames through (in-flight USB /
    # FTDI FIFO), spliced on with a multi-minute timestamp gap.  So hold the first
    # second in memory and drop everything up to the last timestamp discontinuity:
    # that boundary IS the start of this run's data.
    pending = []
    settled = False
    n_stale = 0
    n_ok = n_crc = n_short = 0
    t0 = time.time()
    last = 0.0
    # The cue tones are logged in the same rows as the data, so the analysis has
    # the intended press times rather than having to infer them from the signal.
    cue = {"mark": 0, "n": 0, "stop": False}
    def cue_thread():
        # Absolute scheduling: each cue is placed at t0 + cue_after + n*period so
        # the 70 ms the tone blocks for cannot accumulate.  Beeping first and
        # marking after would put every mark one tone-length late.
        base = t0 + a.cue_after
        n = -a.cue_leadin          # negative n = lead-in ticks
        while not cue["stop"]:
            due = base + (n + a.cue_leadin) * a.cue_period
            while time.time() < due:
                if cue["stop"]: return
                time.sleep(min(0.02, due - time.time()))
            if n < 0:              # ready tick, not a press
                cue["mark"] = 3
                if winsound: winsound.Beep(400, 40)
                n += 1
                continue
            cue["mark"] = 1; cue["n"] = n + 1
            if winsound: winsound.Beep(1000, 60)
            if a.cue_hold > 0:
                rel = due + a.cue_hold
                while time.time() < rel:
                    if cue["stop"]: return
                    time.sleep(min(0.02, rel - time.time()))
                cue["mark"] = 2
                if winsound: winsound.Beep(500, 60)
            n += 1

    if a.cue_period > 0:
        threading.Thread(target=cue_thread, daemon=True).start()
        print("cue every %.2f s%s, starting at %.1f s"
              % (a.cue_period,
                 (" holding %.2f s" % a.cue_hold) if a.cue_hold else "",
                 a.cue_after))
    bid = {"v": None}
    print("capturing... Ctrl+C to stop")
    try:
        while True:
            if a.secs and time.time() - t0 >= a.secs:
                break
            chunk = ser.read(512)
            if chunk:
                buf.extend(chunk)
            # consume as many frames as are complete
            while True:
                i = buf.find(bytes([SYNC0, SYNC1]))
                if i < 0:
                    if len(buf) > 4096:
                        del buf[:-1]          # keep a byte in case of a split sync
                    break
                if len(buf) < i + 3:
                    del buf[:i]
                    break
                ln = buf[i + 2]
                if ln == 0 or ln > 64:
                    del buf[:i + 2]           # implausible length: resync
                    n_short += 1
                    continue
                if len(buf) < i + 3 + ln:
                    del buf[:i]
                    break
                p = bytes(buf[i + 3 : i + 3 + ln])
                del buf[: i + 3 + ln]
                if len(p) < 51 or crc16(p[:49]) != int.from_bytes(p[49:51], "big"):
                    n_crc += 1
                    continue
                ts, dims, mask, dead, st = decode(p)
                # dim 4 carries the bitstream's BUILD_ID (see dsp_chain.v).  It is
                # printed once per run because there are three ways to end up
                # running something other than what was last built: SRAM loses its
                # image on power loss, RESET reloads from internal flash, and
                # Gowin's "Verify Failed at 0" is a false alarm in both directions.
                if bid["v"] is None:
                    bid["v"] = dims[4] & 0xFFFF
                    print("bitstream BUILD_ID = 0x%04X" % bid["v"])
                t = time.time() - t0
                row = ("%.4f,%d,%s,%d,%d,%d,%d\n"
                       % (t, ts, ",".join(str(v) for v in dims), mask, dead, st,
                          cue["mark"]))
                cue["mark"] = 0
                if not settled:
                    pending.append((ts, row))
                    if t >= 1.0:
                        cut = 0
                        for j in range(1, len(pending)):
                            if (pending[j][0] - pending[j - 1][0]) & 0xFFFFFFFF != 1:
                                cut = j
                        n_stale = cut
                        for _, r in pending[cut:]:
                            f.write(r)
                        pending = []
                        settled = True
                else:
                    f.write(row)
                n_ok += 1
                if t - last > 0.15:
                    last = t
                    f.flush()
                    print("\r t=%6.2fs  %5.0f/s  frames=%7d  bad=%3d  cues=%3d  "
                          "dead=0x%05X  d0=%7d d1=%7d d2=%7d   "
                          % (t, n_ok / t if t else 0, n_ok, n_crc, cue["n"],
                             dead, dims[0], dims[1], dims[2]), end="", flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        cue["stop"] = True
        # The settling buffer has to be drained BEFORE the file is closed.
        # Closing first raised "I/O operation on closed file" and threw away the
        # whole capture whenever the run ended while rows were still pending --
        # which is every --secs run short enough that the stream never settled.
        ser.close()
        el = time.time() - t0
        for _, r in pending:
            f.write(r)
        f.close()
        kept = n_ok - n_stale          # the stale prefix never reached the file
        print("\n\nframes %d in %.1fs (%.0f/s) | badCRC %d | resync %d | dropped %d stale"
              % (kept, el, kept / el if el else 0, n_crc, n_short, n_stale))
        if n_ok:
            print("dead map 0x%05X -> dims %s"
                  % (dead, [i for i in range(18) if dead >> i & 1] or "none"))
        print("-> %s" % a.out)

if __name__ == "__main__":
    main()
