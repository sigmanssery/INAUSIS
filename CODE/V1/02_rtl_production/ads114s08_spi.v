// ads114s08_spi.v
// ADS114S08 SPI master — Phase 1 bring-up version (v2, hardware-validated timing)
//
// REWRITTEN 2026-06-17 after real-hardware bring-up (関1) on the Tang Nano 9K.
// The previous version returned garbage (0000/8005). Root cause was NOT wiring/
// mode/chip (all verified good) but two bugs in THIS file, both now fixed:
//
//   BUG 1 — FSM handshake RACE: the old FSM pulsed spi_start and transitioned/
//     captured in the SAME cycle, but the engine only asserts spi_busy the NEXT
//     cycle. So the capture state ran one cycle too early and latched STALE
//     spi_rx (the 0000/8005), and the DR/channel-switch WREGs were eaten.
//     FIX: race-free ISSUE -> WAIT(spi_done) -> capture. Every transaction is
//     issued (1-cycle spi_start pulse) then we wait for the engine's spi_done
//     pulse before doing anything else.
//
//   BUG 2 — engine drops the LAST clocked bit (CS deasserts on the final
//     sclk_fall before a final rising). Empirically (proven via ads_regcheck on
//     real HW) BOTH read and write need total_bits = useful_bits + 1. E.g. a
//     3-byte (24-bit) WREG/RREG must clock 25; RDATA (8 cmd + 16 data) clocks
//     25 and the 16-bit result lands in spi_rx[15:0]. Single-byte commands
//     (RESET/START, 8 bits) clock 8 (validated: RESET at 8 reset the device).
//
// Validation (ads_regcheck.v, real HW): RREG DATARATE returned its reset 0x14
// exactly; WREG DATARATE=0x1A then RREG read back 0x1A; ID reg = 0x0C, stable.
// The bit ENGINE/divider/edges below are the ORIGINAL (the ADS responds to
// them) — only spi_done was added; the FSM and bit counts are the fix.
//
// SPI Mode 1-ish: SCLK idle LOW, DIN shifted on falling, DOUT sampled on rising.
// Clock: 27 MHz; SPI ~1.93 MHz (CLK_DIV=14). Ports unchanged (top_bringup /
// ttcgs_board instantiate this as-is).

module ads114s08_spi #(
    // ─── SINGLE_CH: convert one input instead of cycling all four ────────────
    // Four-channel round-robin costs a factor of four on the channel that has a
    // sensor on it, because it waits out three conversions of inputs sitting at
    // 0-2 counts. It also pays a 52 us INPMUX write per channel that is not
    // needed when the mux never changes.
    //
    //   SINGLE_CH = 0   1713 us x 4   ->  146 SPS per channel
    //   SINGLE_CH = 1   1713 us       ->  584 SPS on the selected input
    //
    // The INPMUX write is kept even though the mux never moves: dropping it to
    // save 52 us put START immediately after the read and railed 37% of samples
    // at +FS. Do not remove it again.
    //
    // NOTE: this is the CONVERSION rate. What reaches the host is set by
    // STREAM_MODE in top_dual.v, which was emitting one set of lines every
    // 10 ms - so every capture before 2026-08-17 is 100 Hz data regardless of
    // what the converter was doing.
    //
    // 86% of the remaining time is the conversion itself (1250 us at DR = 800
    // SPS plus 218 us of single-shot start-up), so DATARATE is the next lever
    // if more is wanted - 0x3A -> 0x3D gives about 1500 SPS, at the cost of
    // noise. Measure before spending that.
    //
    // SINGLE_IDX indexes mux_table: 0 = AIN5 (corner B), 1 = AIN4 (A),
    // 2 = AIN1 (D), 3 = AIN0 (C).
    parameter        SINGLE_CH  = 0,
    parameter [1:0]  SINGLE_IDX = 2'd0,
    // MUX_FORCE overrides INPMUX with a literal register value; 0 = off.  It
    // exists for one experiment: 8'hCC selects AINCOM for BOTH inputs, which
    // disconnects the modulator's sampling capacitors from the sensor pins
    // inside the chip.  That is the same test as physically unplugging the FSR
    // from the analog input, without touching the hardware, and it separates
    // "the inductive channel is disturbed because the modulator is sampling the
    // node the coil shares" from "the inductive channel is disturbed by the
    // ADS's supply or digital activity".  Diagnostic only -- the converter reads
    // its own offset in this mode, so d12/d0-d2 are meaningless while it is set.
    parameter [7:0]  MUX_FORCE  = 8'h00,
    // DR_FORCE overrides DATARATE; 0 = off.  Diagnostic: 8'h34 is 20 SPS in the
    // same single-shot mode, a 40x cut in how much of the time the converter is
    // actually running.  If a disturbance elsewhere on the board scales with
    // that, it is driven by the conversion activity (supply or digital edges);
    // if it does not move, the converter merely being biased and configured is
    // enough and the activity is not the mechanism.
    parameter [7:0]  DR_FORCE   = 8'h00,
    // REF_FORCE overrides the REF register; 0 = off.  8'h0C keeps REFSEL=11
    // (ratiometric AVDD, the reference actually in use) and changes only REFCON
    // 10 -> 00, powering down the internal 2.5 V reference.  That reference is
    // not selected, so nothing about the conversion changes; it was left on only
    // so it "could still be used".  It runs whenever the device is configured
    // and does not care about the data rate, which is the signature the
    // inductive-channel disturbance showed.
    parameter [7:0]  REF_FORCE  = 8'h00,
    // ─── CS_LOW: hold chip select asserted permanently ───────────────────────
    // On the 2026-09 carrier the CS net cannot be driven to a valid high: the
    // FPGA pad reaches 3.33 V with the wire lifted, but with it connected the
    // line clamps at 1.01 V at DRIVE=8 and only 1.35 V at DRIVE=24 -- a junction
    // plus series resistance somewhere on the sensor side, measuring 480 ohm to
    // ground and surviving repeated cleaning.  V_IH for this part is about
    // 2.31 V, so no drive setting available reaches it and the deselected state
    // is unreachable.  Every register write and every START command therefore
    // lands or does not land at random, which is what made the converter appear
    // to work once and fail on the next power-up.
    //
    // The device tolerates CS tied low when it is the only peripheral on the
    // bus, which it is.  The cost is that CS's falling edge no longer
    // resynchronises byte framing, so a single spurious SCLK edge would shift
    // every subsequent read and never recover.  That risk is why this is a
    // parameter and not the default: enable it only on a carrier whose CS is
    // known bad, and watch for the signature -- correct values arriving with a
    // random bit offset.
    parameter        CS_LOW     = 0,
    // ─── CONT_MODE: drive conversions from the START PIN, not the SPI command ──
    // Written for a carrier whose CS cannot reach a valid high (see CS_LOW).  In
    // the default single-shot flow every conversion costs one START command over
    // SPI, so a marginal CS is re-rolled every 1.7 ms and the chain stalls the
    // first time one is lost -- which is exactly how this failure presented.
    //
    // The fix keeps SINGLE-SHOT and changes only where the trigger comes from:
    // the START PIN is pulsed once per conversion instead of the START command
    // being sent over SPI.  The two are the same trigger to the device, but the
    // pin does not pass through the damaged net.  Single-shot is kept rather
    // than switching the device to continuous conversion because both of the
    // behaviours this driver depends on were verified in single-shot: one START
    // gives one clean conversion on the settled mux with no continuous-mode
    // boundary race, and a completed single-shot conversion leaves DRDY# low
    // with the result already driven onto DOUT, which is what makes the 16-clock
    // read with no RDATA command work.  Switching to continuous mode would put
    // both of those on an untested footing to no purpose.  What remains is the
    // one-time register configuration, and that is made robust rather than
    // lucky: every write is read back and retried until it verifies, so a link
    // that lands one transaction in eight still configures reliably -- twenty
    // attempts carry a 12%-per-try success past 92%, and the driver knows which
    // it got instead of assuming.
    //
    // The cost of CS never rising is that its falling edge no longer frames the
    // byte counter, so one spurious SCLK edge would shift every later read and
    // never recover.  DATARATE is therefore re-read every CANARY_N conversions
    // and compared against the value this driver wrote: a mismatch means either
    // the framing slipped or the device lost its configuration, and both are
    // repaired the same way -- go back to POR.  A silently desynchronised
    // converter that keeps emitting plausible numbers is the failure this is
    // here to prevent.
    parameter        CONT_MODE  = 0,
    parameter [15:0] CANARY_N   = 16'd4096
) (
    input  wire        clk,          // 27 MHz
    input  wire        rst_n,        // active-low reset

    // ADS114S08 physical pins
    output reg         ads_cs_n,
    output reg         ads_sclk,
    output reg         ads_din,
    input  wire        ads_dout,
    input  wire        ads_drdy_n,
    output reg         ads_start,    // START pin (assert for continuous conv)

    // Output to downstream logic
    output reg         data_valid,
    output reg [15:0]  data_out,
    output reg [1:0]   ch_out,
    output reg         init_done,
    output reg         err_flag,
    // Bring-up observability.  {drdy_fall_cnt[10:0], state[4:0]}, routed to a
    // spare frame dim by ttcgs_board.  Added 2026-09-03: the ADS was producing
    // no data while init_done read 1 and a DC meter showed DRDY# steady at
    // 3.27 V -- which cannot distinguish "never asserts" from "asserts for 1%
    // of the time", because a 584 SPS pulse train averages to the rail.  The
    // counter settles it: if it advances, DRDY# is asserting and the fault is
    // downstream; if it stays at zero, no conversion ever completes.
    output wire [15:0] dbg_state
);

// ─── SPI clock divider (VERBATIM original) ─────────────────────────────────────
// 2026-07-03: was 14 (~1.93 MHz). On the current wiring ~32% of reads came back
// bit-misaligned or railed (0x7Fxx) in EVERY bitstream — ADS-only, dual-simul
// and dual-timemux alike — i.e. a marginal SPI link, not core interference.
// 56 -> 27 MHz / 56 = ~482 kHz, 4x the setup/hold margin over long jumpers.
// SCLK period is CLK_DIV system clocks (counter wraps at CLK_DIV, falling
// strobe at CLK_DIV/2) -- NOT 2*CLK_DIV. Comments here said 241 kHz by
// dividing by 112; corrected 2026-08-07 after a logic analyser measured
// 2.074 us/clock = 482 kHz. See DATA/2026-08-07_ADS-SPI-DRDY_*.sr.
// Counter widened to 8 bits to hold the larger count. Raise back once the
// harness is short/properly grounded, if the extra sample rate is wanted.
localparam CLK_DIV = 56;            // 27 MHz / 56 = ~482 kHz
localparam PARK_PHASE = 28;         // idle phase: next strobe is the RISE at 55
reg [7:0]  clk_cnt;
reg        sclk_en;                 // rising-edge strobe
reg        sclk_fall;               // falling-edge strobe
reg        spi_start, spi_busy, spi_done;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        clk_cnt   <= 0;
        sclk_en   <= 0;
        sclk_fall <= 0;
    end else begin
        sclk_en   <= 0;
        sclk_fall <= 0;
        // 2026-08-22: park at PARK_PHASE while idle so every transaction starts
        // from the same divider phase AND meets it with a RISING strobe first --
        // SCLK idles low and the ADS is SPI mode 1, so the first edge of a
        // transaction must be a rise. 28 puts the first rise 28 clk (1.04 us)
        // after CS falls, far beyond the 20 ns t_d(CSSC) the datasheet asks.
        if (!spi_busy) begin
            clk_cnt <= PARK_PHASE;
        end else if (clk_cnt == CLK_DIV - 1) begin
            clk_cnt <= 0;
            sclk_en <= 1;
        end else if (clk_cnt == (CLK_DIV/2) - 1) begin
            sclk_fall <= 1;
            clk_cnt   <= clk_cnt + 1;
        end else begin
            clk_cnt <= clk_cnt + 1;
        end
    end
end

// ─── DRDY# falling-edge detect (VERBATIM original) ─────────────────────────────
reg drdy_r0, drdy_r1;
wire drdy_fall   = drdy_r0 & ~drdy_r1;   // ads_drdy_n 0->1 (deassert)  [unused in single-shot]
wire drdy_assert = drdy_r1 & ~drdy_r0;   // ads_drdy_n 1->0 = DATA READY (single-shot)

reg [10:0] drdy_fall_cnt;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n)          drdy_fall_cnt <= 11'd0;
    else if (drdy_assert) drdy_fall_cnt <= drdy_fall_cnt + 11'd1;
end
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin drdy_r0 <= 1'b1; drdy_r1 <= 1'b1; end
    else begin drdy_r1 <= drdy_r0; drdy_r0 <= ads_drdy_n; end
end

// ─── Channel MUX table (VERBATIM): AINP=AIN5/4/1/0, AINN=AINCOM(0xC) ───────────
// MUX_FORCE, when set, overwrites EVERY entry rather than being applied at the
// point of use.  It has to be done here, because mux_table is read from two
// places and only one of them used to consult MUX_FORCE:
//   * mux_sel (the CONT_MODE config write)      -- honoured MUX_FORCE
//   * S_MUX_I (the per-conversion INPMUX write) -- did NOT
// and S_MUX_I is reached from the zero-sample retry in S_RDATA_C, which is not
// guarded by CONT_MODE.  So a single zero reading -- precisely what a loose
// connection produces -- rewrote INPMUX to mux_table[0] (AIN5) and the converter
// then stayed on that input for good, since CONT_MODE never rewrites the mux
// from mux_sel again without a full re-init.  The board reported the expected
// BUILD_ID while quietly reading a different corner.  Folding the override into
// the table fixes every reader at once and, being elaboration-time, adds no
// logic to the datapath -- the ternary version cost a logic level and pushed
// Fmax to 27.001 MHz.  (2026-09-12)
reg [7:0] mux_table [0:3];
initial begin
    mux_table[0] = (MUX_FORCE != 8'h00) ? MUX_FORCE : 8'h5C; // AIN5
    mux_table[1] = (MUX_FORCE != 8'h00) ? MUX_FORCE : 8'h4C; // AIN4
    mux_table[2] = (MUX_FORCE != 8'h00) ? MUX_FORCE : 8'h1C; // AIN1
    mux_table[3] = (MUX_FORCE != 8'h00) ? MUX_FORCE : 8'h0C; // AIN0
end

// ─── SPI byte engine (VERBATIM original) + spi_done pulse ──────────────────────
reg [23:0] load_data, shift_out, spi_rx;
reg [5:0]  total_bits, bit_cnt;
reg        cs_rel;      // last fall seen; release CS on the next rise

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        ads_cs_n <= (CS_LOW || CONT_MODE) ? 1'b0 : 1'b1;
        ads_sclk  <= 1'b0;
        ads_din   <= 1'b0;
        spi_busy  <= 1'b0;
        spi_done  <= 1'b0;
        spi_rx    <= 24'h0;
        bit_cnt   <= 0;
        shift_out <= 24'h0;
        cs_rel    <= 1'b0;
    end else begin
        spi_done <= 1'b0;
        if (spi_start && !spi_busy) begin
            ads_cs_n  <= 1'b0;
            ads_sclk  <= 1'b0;
            bit_cnt   <= total_bits - 1;
            cs_rel    <= 1'b0;
            spi_busy  <= 1'b1;
            shift_out <= load_data;
        end
        if (spi_busy) begin
            // ── SPI MODE 1, per ADS114S08 datasheet Fig. 1 / Fig. 2 ──────────
            // DIN  is latched by the device on the SCLK FALLING edge
            //      (t_su(DI) 15 ns before it, t_h(DI) 20 ns after it), so MOSI
            //      must be launched on the RISING edge -- half a period, 1.0 us
            //      of setup, instead of the setup violation launching it on the
            //      fall used to give.
            // DOUT is updated by the device on the SCLK RISING edge
            //      (t_p(SCDO) 3-30 ns after it), so MISO must be sampled on the
            //      FALLING edge. Sampling it on the rise, as this engine did,
            //      raced that 3-30 ns window: sometimes the old bit, sometimes
            //      the new one -- which is exactly the intermittent halving.
            // One SCLK period now carries exactly one bit in each direction, so
            // total_bits is the true bit count and every "+1" is gone.
            if (sclk_en && !cs_rel) begin
                ads_sclk  <= 1'b1;
                ads_din   <= shift_out[23];
                shift_out <= {shift_out[22:0], 1'b0};
            end
            if (sclk_fall) begin
                ads_sclk <= 1'b0;
                spi_rx   <= {spi_rx[22:0], ads_dout};
                if (bit_cnt == 0) cs_rel <= 1'b1;   // hold CS one more half-period
                else              bit_cnt <= bit_cnt - 1;
            end
            // t_d(SCCS): CS may not rise until 20 ns after the last falling
            // edge. Releasing on the next rise strobe gives a full half period.
            if (sclk_en && cs_rel) begin
                ads_cs_n <= (CS_LOW || CONT_MODE) ? 1'b0 : 1'b1;
                spi_busy <= 1'b0;
                spi_done <= 1'b1;
                cs_rel   <= 1'b0;
            end
        end
    end
end

// ─── Main FSM — race-free ISSUE -> WAIT(spi_done) -> capture ───────────────────
// Sequence: RESET -> WREG REF -> WREG DATARATE (single-shot) -> then per channel:
//           { WREG INPMUX(ch) -> START(one conv) -> wait DRDY -> RDATA ->
//             capture -> next ch }. SINGLE-SHOT: one START = one clean conversion
//           on the selected mux, so there is NO continuous-mode boundary race.
//
// Bit counts (BUG 2): single-byte cmds=8; 3-byte WREG=25; RDATA(8+16)=25,
// data in spi_rx[15:0].
localparam [4:0]
    S_POR      = 5'd0,
    S_RST_I    = 5'd1,
    S_RST_GAP  = 5'd2,
    S_REF_I    = 5'd3,
    S_DR_I     = 5'd4,
    S_MUX_I    = 5'd5,
    S_START_I  = 5'd6,
    S_WAITDR   = 5'd7,
    S_RDATA_I  = 5'd8,
    S_RDATA_C  = 5'd9,
    S_WAIT     = 5'd10,
    S_BACKOFF  = 5'd11,
    // CONT_MODE only: write-verify-retry of the configuration, then the canary.
    S_CFG_W    = 5'd12,   // issue WREG for cfg_i
    S_CFG_R    = 5'd13,   // issue RREG for the same register
    S_CFG_C    = 5'd14,   // compare, advance or retry
    S_CAN_I    = 5'd15,   // issue RREG DATARATE
    S_CAN_C    = 5'd16,   // compare against VAL_DR
    S_STARTP   = 5'd17,   // pulse the START pin: one conversion, no SPI
    S_FLUSH    = 5'd18,   // 3 bytes of NOP: harmless at any bit alignment
    S_NUDGE    = 5'd19;   // clock ONE bit to advance the alignment by one

reg [4:0]  state, ret_state;
assign dbg_state = {drdy_fall_cnt, state};   // 見埠宣告處的說明

// ─── CONT_MODE configuration table and bookkeeping ────────────────────────────
// Three registers must land before conversions mean anything: REF selects the
// ratiometric AVDD reference, DATARATE sets the rate (and is also the canary,
// because its value is one this driver chose and can therefore check exactly),
// INPMUX selects the input.  Verified in that order.
reg  [1:0]  cfg_i;
reg  [5:0]  cfg_try;
reg  [15:0] canary_cnt;
localparam [5:0] CFG_TRY_MAX = 6'd40;      // ~40 attempts; see CONT_MODE note
// START pulse width.  The datasheet asks for tens of nanoseconds; 27 clocks is
// 1 us, generous enough that no edge rate on this harness can shorten it below
// the requirement, and short enough to be invisible against a 1.7 ms conversion.
localparam [5:0] STARTP_CLKS = 6'd27;
reg [5:0] startp_cnt;

// ─── Byte-alignment search (CONT_MODE) ───────────────────────────────────────
// The device counts bytes from the falling edge of CS, so CS rising is the only
// thing that resynchronises it.  Holding CS low removes that, and an FPGA
// reconfiguration drives SCLK through an undefined state on the way to the new
// bitstream: the device can pick up a stray edge and every transaction after it
// is offset by that many bits, permanently.  Measured 2026-09-04: this driver
// configured and converted twice, then went dead across a reflash and STAYED
// dead through four more, which is the signature -- a marginal link fails
// randomly, a lost byte boundary fails and stays failed.
//
// The offset is at most 7 bits, so it is searched rather than suffered.  A
// failed read-back clocks one extra bit and tries again, walking the alignment
// one step per attempt; within eight attempts the framing must be right.  The
// old loop retried the SAME alignment forty times, which is why it never
// recovered.  Each pass is preceded by three bytes of 0x00: NOP is 0x00 on this
// device, and an all-zero run decodes as NOP at EVERY alignment, so it flushes
// a half-received command without needing to know where the boundary is.
reg [2:0] align_n;
wire [7:0] mux_sel  = (MUX_FORCE != 8'h00) ? MUX_FORCE : mux_table[SINGLE_IDX];
wire [7:0] cfg_addr = (cfg_i == 2'd0) ? 8'h05 :
                      (cfg_i == 2'd1) ? 8'h04 : 8'h02;
wire [7:0] cfg_val  = (cfg_i == 2'd0) ? VAL_REF :
                      (cfg_i == 2'd1) ? VAL_DR  : mux_sel;
reg [20:0] wait_cnt;          // up to ~78 ms
reg [1:0]  ch_idx;

// ── bounded re-init, then slow retry ─────────────────────────────────────────
// The zero-run heuristic below CANNOT tell a lost init from an open-circuit
// divider.  With counts = 32767 * 100k/(100k + R), an absent sensor is R -> inf
// and reads exactly 0, with nothing to dither the LSBs -- the same symptom the
// heuristic reads as "the converter never woke".  Retrying forever then turns a
// legitimately absent channel into a continuous SPI aggressor.
//
// Measured 2026-09-03 with no FSR fitted: the driver re-initialised about nine
// times a second, and on the same board that corrupted 32% of the LDC's CHIP_ID
// reads (ldc_alive fell from 100% to 68.2%, dropouts locked to a 280 Hz beat,
// RP's standard deviation went from ~5 to 818 counts).  An absent sensor must
// fail QUIETLY: it is a normal configuration, and across a cluster it is the
// common one.
//
// So: keep the fast retries, because the cold-start case needs them (register
// writes lost to a ramping supply, recovered by redoing the sequence), but bound
// them.  Twelve attempts is about 1.8 s, comfortably longer than a cold start.
// After that, retry once every ~5 s instead of ~9 times a second -- a 45x drop
// in disturbance that still recovers if a sensor is fitted later.  err_flag is
// raised on giving up, so the host sees "not producing data" in status bit 7
// rather than having to infer it from a channel that reads zero.
localparam [3:0]  REINIT_MAX = 4'd12;
localparam [27:0] BACKOFF_CLKS = 28'd135_000_000;   // ~5 s at 27 MHz
reg [3:0]  reinit_cnt;
reg [27:0] backoff_cnt;

// Self-heal: a converter that is alive never returns exactly 0 many times in a
// row -- its own noise dithers the LSBs.  A run of them means the init writes
// were lost, so redo the whole sequence rather than streaming zeros forever.
// This is the same shape as the LDC driver's chip-ID re-init.
localparam [7:0] ZERO_RUN_MAX = 8'd64;
reg [7:0] zero_run;

// ─── RD_REPEAT: read each conversion several times, keep the largest ──────────
// The divider below free-runs, so CS falls at an arbitrary point in its 56-clock
// period and the transaction contains either 16 or 17 SCLK rising edges. Reads
// sample MISO on rises, so one edge fewer means one bit fewer and the captured
// word is exactly HALF. Measured on a fixed 100 kohm: 38-52% of reads halved,
// and the proportion is not reproducible across power cycles (one session ran at
// 100%).
//
// Only reads are affected. Writes shift MOSI on falls and the fall count is
// fixed, which is why the config WREGs always verified. And only THIS read is
// exposed, because it is a direct read carrying no command byte (see S_RDATA_I)
// -- there is nothing for the device to frame against, so the bit alignment is
// set purely by CS phase.
//
// Rather than chase that phase (four attempts on 2026-08-16 each made it worse
// or stopped conversion entirely -- see git history), this is immune by
// construction: corruption only ever HALVES, so the largest of N reads is
// correct unless all N were corrupted. In single-shot the data register holds
// its value until the next START, so re-reading returns the same conversion.
//
//   1 read   ~44% wrong        4 reads  2.6%
//   2 reads   19%              5 reads  1.0%
//   3 reads  7.7%              6 reads  0.4%
//
// Cost: 4 extra 35 us transactions per channel on a 1572 us conversion, so
// 159 -> ~138 SPS per channel.
//
// Compare on MAGNITUDE, not value: halving moves a negative reading UP, so a
// plain unsigned max would pick the corrupted one on channels sitting near zero.
localparam [2:0] RD_REPEAT = 3'd1;   // BISECT state that built the 08-19 data
reg [15:0] rd_max;
reg [2:0]  rd_cnt;

function [15:0] absv;
    input [15:0] x;
    begin absv = x[15] ? (~x + 16'd1) : x; end
endfunction
// SINGLE-SHOT per channel: set MUX, START one conversion, wait its DRDY, read.
// Each conversion is taken fully on the selected mux AFTER it settled, so there
// is no continuous-mode boundary race -> no more intermittent 0x7F8D (~+FS) rails.

// 2026-08-28: raised 135000 (5 ms) -> 1350000 (50 ms).  With the bitstream in
// the FPGA's embedded flash the board cold-starts: the converter's supply is
// still ramping when configuration completes, the init WREGs land in a device
// that is not listening, and it sits in its default state converting nothing.
// Symptom on a cold plug-in, seen 2026-08-28: frames flow at 690/s with good
// CRC, but every reading is exactly 0 and the flag engine's power-on
// calibration therefore measures zero variance and marks all 18 dims dead
// (dead = 0x3FFFF).  Reloading the SAME bitstream over JTAG works, because by
// then the converter has been powered for minutes -- which is why this never
// showed up in months of JTAG-loaded bring-up.
localparam [20:0] POR_CYC = 21'd1350000;  // ~50 ms power-on
localparam [20:0] GAP_CYC = 21'd270000;   // ~10 ms after RESET

// REF: REFSEL=10 (internal 2.5V), REFCON=10 (always on). VERIFY/TUNE for tank/sensor.
// 2026-08-25: REFSEL 10 (internal 2.5 V) -> 11 (AVDD/AVSS), i.e. RATIOMETRIC.
// The sensor is a resistive divider excited from the analog supply, so measuring
// it against an independent 2.5 V reference turns every millivolt of supply noise
// into a proportional error on the reading -- observed as a constant 10.8% of
// reading at both 240 and 480 counts, unchanged when the SPI clock was halved.
// Referred to AVDD the reading becomes a pure resistance ratio and supply noise
// cancels.
//
// 2026-09-04: REFCON 10 -> 00.  REFSEL=11 means the internal 2.5 V reference is
// NOT the reference in use; it was left powered only so it "could still be
// used", and it costs far more than it looked.  Powering it down measured, with
// nothing else changed: this converter's own noise 17.11 -> 1.31 counts sd
// (13x), and -- on a separate SPI bus, a separate chip -- the inductive
// channel's d15 sd 1195.7 -> 28.5 (42x) with its CHIP_ID read-back going from
// 77.4% to 100.00%.  It was the dominant disturbance on BOTH converters.
// Ruled out first, one build each: star ground (77.94 -> 78.08%), coupling
// through the sensor stack (INPMUX = AINCOM/AINCOM, no change), and conversion
// activity (20 SPS, no change).  Rate-independence is what pointed at something
// that runs merely because the device is configured.
localparam [7:0] VAL_REF = (REF_FORCE != 8'h00) ? REF_FORCE : 8'h0C;
// DATARATE(04h): [7]=0 [6]=CLK src [5]=MODE [4]=FILTER [3:0]=DR.
// 0x3A = MODE 1 (single-shot) + FILTER 1, DR = 800 SPS, CLK = internal.
//
// EXT_CLK=1 additionally sets bit6 -> take the system clock from the CLK pin.
// The internal oscillator is 4.096 MHz with only 2% accuracy AND "the data rate
// scales with internal oscillator variation" — so the sample rate drifts with
// temperature. TTCGS defines its DoG sigmas in SAMPLES, so a drifting rate drags
// the claimed passbands with it. Driving CLK from the FPGA makes the rate
// crystal-accurate (+-20 ppm) and coherent with the LDC's CLKIN.
//   Allowed fCLK is 2-4.5 MHz (need NOT be 4.096): 27 MHz/7 = 3.857 MHz is the
//   closest with margin, and scales every data rate by 0.942 (800 -> 753 SPS).
// Only enable once the board actually routes FPGA -> ADS CLK; with the pin left
// at DGND the device must stay on the internal oscillator.
// NOTE: a RESET (pin or command) reverts the device to the internal oscillator,
// so this bit has to be re-applied on every init — it is, since DATARATE is
// written after the reset in the sequence below.
localparam EXT_CLK = 1'b0;
localparam [7:0] VAL_DR  = (DR_FORCE != 8'h00) ? DR_FORCE : (EXT_CLK ? 8'h7A : 8'h3A);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state      <= S_POR;
        ret_state  <= S_POR;
        wait_cnt   <= 21'd0;
        spi_start  <= 1'b0;
        load_data  <= 24'h0;
        total_bits <= 6'd8;
        data_valid <= 1'b0;
        data_out   <= 16'h0;
        ch_out     <= 2'h0;
        ch_idx     <= SINGLE_CH ? SINGLE_IDX : 2'h0;
        init_done  <= 1'b0;
        err_flag   <= 1'b0;
        ads_start  <= 1'b0;
        rd_max     <= 16'h0;
        rd_cnt     <= 3'd0;
        zero_run   <= 8'd0;
        reinit_cnt <= 4'd0;
        backoff_cnt<= 28'd0;
        cfg_i      <= 2'd0;
        cfg_try    <= 6'd0;
        canary_cnt <= 16'd0;
        startp_cnt <= 6'd0;
        align_n    <= 3'd0;
    end else begin
        spi_start  <= 1'b0;
        data_valid <= 1'b0;

        case (state)
        // ── power-on wait ─────────────────────────────────────────────────
        S_POR: begin
            if (wait_cnt == POR_CYC) begin wait_cnt <= 21'd0; state <= S_RST_I; end
            else wait_cnt <= wait_cnt + 21'd1;
        end
        // ── RESET (0x06, single byte = 8 bits) ────────────────────────────
        S_RST_I: begin
            load_data <= {8'h06, 16'h0}; total_bits <= 6'd8;
            spi_start <= 1'b1; ret_state <= S_RST_GAP; state <= S_WAIT;
        end
        S_RST_GAP: begin
            if (wait_cnt == GAP_CYC) begin
                wait_cnt <= 21'd0;
                if (CONT_MODE) begin
                    cfg_i <= 2'd0; cfg_try <= 6'd0; align_n <= 3'd0;
                    state <= S_FLUSH;
                end else state <= S_REF_I;
            end else wait_cnt <= wait_cnt + 21'd1;
        end

        // 3 bytes of 0x00.  NOP at any alignment, so it clears a partially
        // received command without knowing where the byte boundary is.
        S_FLUSH: begin
            load_data <= 24'h000000; total_bits <= 6'd24;
            spi_start <= 1'b1; ret_state <= S_CFG_W; state <= S_WAIT;
        end

        // One bit.  Because CS stays low this does not end a frame -- it simply
        // advances where the device thinks the next byte starts, which is the
        // whole point.
        S_NUDGE: begin
            load_data <= 24'h000000; total_bits <= 6'd1;
            spi_start <= 1'b1; ret_state <= S_FLUSH; state <= S_WAIT;
        end

        // ── CONT_MODE: write a register, read it back, retry until it agrees ──
        S_CFG_W: begin
            load_data <= {8'h40 | cfg_addr, 8'h00, cfg_val}; total_bits <= 6'd24;
            spi_start <= 1'b1; ret_state <= S_CFG_R; state <= S_WAIT;
        end
        S_CFG_R: begin
            // 24, not 25.  The "+1" in the file header belongs to the ORIGINAL
            // engine and was retired when the sampling edge was fixed (see the
            // engine comment: one SCLK period now carries exactly one bit).  All
            // three working WREGs below clock 24 and RDATA clocks 16.  With CS
            // held low the extra bit is not merely a bad read: nothing resyncs
            // the byte counter afterwards, so every later transaction is shifted
            // by one bit for good.
            load_data <= {8'h20 | cfg_addr, 8'h00, 8'hFF};   total_bits <= 6'd24;
            spi_start <= 1'b1; ret_state <= S_CFG_C; state <= S_WAIT;
        end
        S_CFG_C: begin
            if (spi_rx[7:0] == cfg_val) begin
                cfg_try <= 6'd0;
                if (cfg_i == 2'd2) begin
                    // All three verified.  Conversions start only now: a trigger
                    // issued before the rate and reference are known would
                    // produce samples nothing downstream could interpret.
                    init_done  <= 1'b1;
                    err_flag   <= 1'b0;
                    canary_cnt <= 16'd0;
                    startp_cnt <= 6'd0;
                    state      <= S_STARTP;
                end else begin
                    cfg_i <= cfg_i + 2'd1; state <= S_CFG_W;
                end
            end else if (cfg_try == CFG_TRY_MAX) begin
                // Every alignment tried, several times over: the link is not
                // merely misframed.  Say so in err_flag and back off rather than
                // run on a configuration nothing has confirmed.
                err_flag    <= 1'b1;
                backoff_cnt <= BACKOFF_CLKS;
                state       <= S_BACKOFF;
            end else begin
                // Advance the alignment and restart from the first register: a
                // partial pass proves nothing once the framing has moved.
                cfg_try <= cfg_try + 6'd1;
                align_n <= align_n + 3'd1;
                cfg_i   <= 2'd0;
                state   <= S_NUDGE;
            end
        end

        // ── CONT_MODE: one conversion per START-pin pulse, no SPI involved ────
        S_STARTP: begin
            ads_start <= 1'b1;
            if (startp_cnt == STARTP_CLKS) begin
                ads_start  <= 1'b0;
                startp_cnt <= 6'd0;
                state      <= S_WAITDR;
            end else startp_cnt <= startp_cnt + 6'd1;
        end

        // ── CONT_MODE: canary.  Re-read DATARATE and compare with what we wrote.
        S_CAN_I: begin
            load_data <= {8'h24, 8'h00, 8'hFF}; total_bits <= 6'd24;   // see S_CFG_R
            spi_start <= 1'b1; ret_state <= S_CAN_C; state <= S_WAIT;
        end
        S_CAN_C: begin
            if (spi_rx[7:0] == VAL_DR) state <= S_STARTP;
            else begin
                // Framing slipped or the device lost its configuration.  Both
                // are repaired by starting over; carrying on would emit numbers
                // that look valid and are not.
                init_done <= 1'b0;
                ads_start <= 1'b0;
                wait_cnt  <= 21'd0;
                state     <= S_POR;   // re-init; the trigger stops until verified
            end
        end
        // ── WREG REF (0x05) = internal 2.5V ref. {0x45,0x00,VAL_REF}, 25 bits
        S_REF_I: begin
            load_data <= {8'h45, 8'h00, VAL_REF}; total_bits <= 6'd24;
            spi_start <= 1'b1; ret_state <= S_DR_I; state <= S_WAIT;
        end
        // ── WREG DATARATE = single-shot mode (config ONCE). {0x44,0x00,VAL_DR},25b
        S_DR_I: begin
            load_data <= {8'h44, 8'h00, VAL_DR}; total_bits <= 6'd24;
            spi_start <= 1'b1; init_done <= 1'b1; ret_state <= S_MUX_I; state <= S_WAIT;
        end
        // ── per-channel SINGLE-SHOT: WREG INPMUX(ch). {0x42,0x00,mux}, 25 bits ──
        S_MUX_I: begin
            load_data <= {8'h42, 8'h00, mux_table[ch_idx]}; total_bits <= 6'd24;
            spi_start <= 1'b1; ret_state <= S_START_I; state <= S_WAIT;
        end
        // ── START (0x08): trigger exactly ONE conversion on the settled mux ────
        S_START_I: begin
            load_data <= {8'h08, 16'h0}; total_bits <= 6'd8;
            spi_start <= 1'b1; ret_state <= S_WAITDR; state <= S_WAIT;
        end
        // ── wait THIS conversion's DRDY# ASSERTION (1->0 = data ready) ─────────
        S_WAITDR: begin
            if (drdy_assert) begin
                rd_max <= 16'h0; rd_cnt <= 3'd0; state <= S_RDATA_I;
            end
        end
        // ── DIRECT read: single-shot leaves DRDY# LOW, so the ADS already drives
        //    the conversion data onto MISO. Read it by clocking 16(+1) bits with NO
        //    RDATA command (0x12 would collide with that auto-output -> byte shift).
        S_RDATA_I: begin
            load_data <= 24'h0; total_bits <= 6'd16;       // 16-bit result, one bit per SCLK period
            spi_start <= 1'b1; ret_state <= S_RDATA_C; state <= S_WAIT;
        end
        // ── capture: keep the largest-magnitude of RD_REPEAT reads (see above) ─
        S_RDATA_C: begin
            if (rd_cnt == RD_REPEAT - 3'd1) begin
                data_out   <= (absv(spi_rx[15:0]) > absv(rd_max)) ? spi_rx[15:0]
                                                                  : rd_max;
                ch_out     <= ch_idx;
                data_valid <= 1'b1;
                // Always go back through S_MUX_I, even when the mux never
                // changes. Skipping it to save 52 us put START immediately
                // after the read and railed 37% of samples at +FS on hardware;
                // the write is also the gap the device needs between them.
                if (!SINGLE_CH) ch_idx <= ch_idx + 2'd1;
                if (((absv(spi_rx[15:0]) > absv(rd_max)) ? spi_rx[15:0]
                                                         : rd_max) == 16'sd0) begin
                    if (zero_run == ZERO_RUN_MAX) begin
                        zero_run  <= 8'd0;
                        init_done <= 1'b0;
                        wait_cnt  <= 21'd0;
                        if (reinit_cnt != REINIT_MAX) begin
                            reinit_cnt <= reinit_cnt + 4'd1;
                            state      <= S_POR;   // converter never woke: redo init
                        end else begin
                            err_flag    <= 1'b1;   // give up loudly, retry slowly
                            backoff_cnt <= BACKOFF_CLKS;
                            state       <= S_BACKOFF;
                        end
                    end else begin
                        zero_run <= zero_run + 8'd1;
                        state    <= S_MUX_I;
                    end
                end else begin
                    reinit_cnt <= 4'd0;            // real data: the channel is fine
                    err_flag   <= 1'b0;
                    zero_run <= 8'd0;
                    if (!CONT_MODE) state <= S_MUX_I;
                    else if (canary_cnt == CANARY_N) begin
                        canary_cnt <= 16'd0; state <= S_CAN_I;
                    end else begin
                        canary_cnt <= canary_cnt + 16'd1; state <= S_STARTP;
                    end
                end
            end else begin
                if (absv(spi_rx[15:0]) > absv(rd_max)) rd_max <= spi_rx[15:0];
                rd_cnt <= rd_cnt + 3'd1;
                state  <= S_RDATA_I;
            end
        end
        // ── gave up on a channel that only ever reads zero: idle, then retry ─
        // No SPI is issued here, which is the whole point: an absent sensor
        // stops disturbing the converters that are present.
        S_BACKOFF: begin
            if (backoff_cnt != 28'd0) backoff_cnt <= backoff_cnt - 28'd1;
            else begin
                reinit_cnt <= 4'd0;
                wait_cnt   <= 21'd0;
                state      <= S_POR;
            end
        end
        // ── shared wait: hold until the SPI transaction actually completes ─
        S_WAIT: begin
            if (spi_done) state <= ret_state;
        end
        default: begin err_flag <= 1'b1; state <= S_POR; end
        endcase
    end
end

endmodule
