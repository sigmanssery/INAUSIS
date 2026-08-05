`timescale 1ns/1ps
//=============================================================================
// ldc1101_spi.v  — LDC1101 sampling SPI master (inductive L + RP)
//
// REWRITTEN 2026-06-17 after real-hardware bring-up. Two fixes vs the prior
// version (both proven on HW via gowin_syn/ldc_regcheck.v, which read
// CHIP_ID=0xD4 and round-tripped a WREG/RREG):
//
//   MODE — SPI MODE 0 (CPOL=0, CPHA=0). SCLK idles LOW; MOSI MSB is presented
//     before the first rising edge; master SAMPLES MISO on the RISING edge and
//     ADVANCES MOSI on the FALLING edge. HISTORY: a prior session flipped this
//     to Mode 3 believing the LDC was Mode 3 (it read D4 on the old separate
//     board). On the INTEGRATED board (2026-07-02) Mode 3 read 0xFF while Mode 0
//     reads 0xD4 (proven via ldc1101_bringup_trace) -> reverted to Mode 0. The
//     LDC1101 is a Mode-0 part; the trace's own off-by-one (dropped the MSB,
//     read D4 as A8) had masked this earlier.
//
//   FIX 2 — race-free FSM. The old per-byte FSM re-issued the SAME byte on the
//     spi_done cycle, so a WREG sent the ADDRESS byte twice and never the DATA
//     byte -> every config write was corrupted (CHIP_ID reads happened to be
//     immune). Now every 2-byte transaction is issued once
//     (ISSUE -> WAIT(spi_done) -> capture) via a 16-bit engine; the read data
//     byte lands in spi_rx[7:0].
//
// Sequence: POR -> WREG config list (RP+L active mode) -> read CHIP_ID (err_flag
// if != 0xD4) -> loop { read RP_DATA(L,H)+L_DATA(L,H) -> emit rp_data/l_data,
// pulse data_valid }. Config values are datasheet-typical and MUST be tuned for
// the actual LC tank on the bench. Ports unchanged (ttcgs_board instantiates
// this as-is). SCLK ~500 kHz.
//=============================================================================
module ldc1101_spi (
    input  wire        clk,          // 27 MHz
    input  wire        rst_n,

    // LDC1101 SPI bus (Mode 0)
    output reg         ldc_cs_n,
    output reg         ldc_sclk,     // idles LOW (Mode 0)
    output reg         ldc_sdi,      // MOSI
    input  wire        ldc_sdo,      // MISO
    output wire        ldc_clkin,    // ~3.375 MHz reference clock for L (clk27/8)

    // to downstream DSP chain
    output reg         data_valid,
    output reg [15:0]  rp_data,
    output reg [15:0]  l_data,
    output reg         init_done,
    output reg         err_flag,     // CHIP_ID mismatch
    // Raw STATUS(0x20) from the last read, latched every loop. bit7 NO_SENSOR_OSC
    // (oscillation stopped — RP fell below RP_SET:RP_MIN), bit6 DRDYB, bit0
    // POR_READ. Exposed so a capture can tell "the tank stalled" apart from "the
    // readout is wrong" without guessing. Safe to leave unconnected.
    output reg [7:0]   status,
    // CHIP_ID(0x3F) re-read on EVERY sample loop, not just at init. 0xD4 = the LDC
    // is answering on SPI; 0xFF/garbage = MISO floating or the part is off the bus.
    // This is what tells a dead link apart from a dead tank — status alone cannot,
    // because a floating MISO reads 0xFF and that also sets NO_SENSOR_OSC.
    output reg [7:0]   chip_id
);
    localparam integer HALF       = 27;        // ~500 kHz SCLK (period = 2*HALF)
    localparam [22:0]  POR_DELAY  = 23'd135000; // ~5 ms power-on wait
    // ~1 kHz RP/L sample loop. FREE_RUN drops the throttle so the loop is paced
    // only by the SPI reads + the LDC's own conversion (RESP_TIME 6144 at
    // fSENSOR ~5 MHz = 403 us, i.e. ~2.5 kSPS) — needed to resolve impact
    // transients and MRE viscoelastic ringing, which alias badly at 93 SPS.
    localparam FREE_RUN = 1'b0;
    localparam [22:0]  LOOP_DELAY = FREE_RUN ? 23'd10 : 23'd27000;

    localparam READ_BIT = 1'b1, WRITE_BIT = 1'b0;
    localparam [6:0] REG_RP_SET=7'h01, REG_TC1=7'h02, REG_TC2=7'h03,
                     REG_DIG_CONF=7'h04, REG_ALT_CONF=7'h05, REG_D_CONF=7'h0C,
                     REG_START_CONF=7'h0B, REG_STATUS=7'h20,
                     REG_RP_DATA_L=7'h21, REG_RP_DATA_H=7'h22,
                     REG_L_DATA_L=7'h23,  REG_L_DATA_H=7'h24, REG_CHIP_ID=7'h3F;
    // Config validated on HW (ldc_regcheck): with CLKIN, L responds to metal.
    // DIG_CONF=0x07 (MIN_FREQ=0 + RESP_TIME=6144) — was 0x06 (RESP_TIME=3072);
    // the longer conversion window scales L_DATA up (finer L resolution) at a
    // lower sample rate, to lift the small dL seen in the MRE presses. RP_SET/
    // TC1/TC2 are still placeholders — RP stays noisy until tuned to the real
    // sensor's RP/Q (a bench-characterization task); L is the clean channel.
    // ── HI-RES mode switch ──────────────────────────────────────────────────
    // 0 = legacy (CLKIN 3.375 MHz, DIG_CONF 0x07, RP_SET 0x07) — the config every
    //     capture up to 2026-07-30 used. Keep for A/B against old data.
    // 1 = datasheet-compliant. The datasheet requires the reference clock to be
    //     "greater than 4 times the sensor frequency"; legacy runs at ratio 0.66
    //     (CLKIN 3.375 MHz vs fSENSOR 5.08 MHz), which is why L_DATA sat at 1361
    //     = 2.1% of the 16-bit full scale and dL was only ~50 counts.
    //     CLKIN 27/2 = 13.5 MHz alone lifts L_DATA to ~5443 (4x) with the EXISTING
    //     220 pF tank (ratio 2.66); swapping the tank to 680 pF puts fSENSOR at
    //     2.89 MHz -> ratio 4.67 (compliant) and L_DATA ~9568 (7x).
    // Split into two knobs so they can be bisected: on the dupont harness a
    // 13.5 MHz CLKIN is already on record as coupling into the LC tank and making
    // L spiky (that is why it was dropped to 3.375 MHz originally), so it may not
    // be testable until the V4 PCB routes CLKIN away from the coil. The register
    // changes are independent of that and should work on either harness.
    // CLKIN divider select: 0 = 27/8 = 3.375 MHz (validated on the dupont harness)
    //                       1 = 27/4 = 6.75  MHz
    //                       2 = 27/2 = 13.5  MHz (kills the tank on dupont — the
    //                           LDC returned RP/L = FFFF; needs the V4 PCB where
    //                           CLKIN is routed away from the coil and guarded)
    localparam [1:0] LDC_CLKIN_SEL = 2'd0;
    localparam LDC_HIRES      = 1'b1;   // 1 = DIG_CONF 0xD7 + RP_SET 0x46

    localparam [7:0] VAL_TC1=8'h59, VAL_TC2=8'h30,   // calibrated for the ~5MHz tank
                     VAL_ALT_CONF=8'h00, VAL_D_CONF=8'h00,
                     VAL_SLEEP=8'h01,    // START_CONFIG sleep/stop (configure in sleep)
                     VAL_ACTIVE=8'h00;   // START_CONFIG active (RP+L conversion)
    // RP_SET 0x07 = RP_MIN 0.75k / RP_MAX 96k — the widest possible range, so the
    // 16-bit RP_DATA is spread over 0.75k..96k and only ~7.2 counts/ohm land near
    // our ~2k sensor. 0x46 = RP_MIN 1.5k / RP_MAX 6k brackets it -> 19.1 counts/ohm.
    //
    // 2026-07-31: 0x46's RP_MIN is TOO HIGH and is the prime suspect for the L
    // bimodality (L_DATA dwelling at ~1365 then ~2320, ~0.5 Hz, whenever the
    // sensor is loaded). Datasheet Table 2 (STATUS): "When the resonance impedance
    // of the sensor, RP, drops below the programmed Rp_MIN, the sensor oscillation
    // MAY STOP ... could occur when a target comes too close to the sensor or if
    // RP_SET:RP_MIN is set too high." Resting RP is ~2.2k — only 1.45x above the
    // 1.5k floor — and a press drops RP by 20-37%, i.e. straight onto it. That
    // explains why L jumps only under load while RP looks unchanged (it is clamped
    // at the bottom of its window), and why a toothpick does nothing.
    // 0x47 = RP_MIN 0.75k / RP_MAX 6k: half the RP resolution, but the oscillator
    // keeps running through a full press. Go back to 0x46 only if STATUS bit7
    // (NO_SENSOR_OSC) proves clean across a loaded capture.
    // 0x46 = RP_MIN 1.5k / RP_MAX 6k -> 19.1 counts/ohm on the ~2.2k tank.
    // 0x47 widens RP_MIN to 0.75k and halves the resolution for no measured
    // benefit (2026-07-31: NO_SENSOR_OSC never fired at either setting, and the
    // press response dropped from -19.3% to -12.2% of full scale). Keep 0x46.
    localparam [7:0] VAL_RP_SET   = LDC_HIRES ? 8'h46 : 8'h07;
    // DIG_CONF: [7:4] MIN_FREQ, [2:0] RESP_TIME. 0x07 leaves MIN_FREQ=0, i.e. the
    // oscillation watchdog set to 0.5 MHz (datasheet: too low = slow to report a
    // stopped sensor). 0xD7 = MIN_FREQ 13 -> 2.667 MHz watchdog, which sits below
    // fSENSOR for both the 220 pF (5.08 MHz) and 680 pF (2.89 MHz) tanks.
    localparam [7:0] VAL_DIG_CONF = LDC_HIRES ? 8'hD7 : 8'h07;
    localparam [7:0] CHIP_ID_EXP = 8'hD4;

    //--------------------------------------------------- CLKIN generator
    // L REQUIRES this reference clock (fSENSOR = fCLKIN*RESP_TIME/(3*L_DATA));
    // RP does not. 27/2 = 13.5 MHz (hi-res) or 27/8 = 3.375 MHz (legacy). Both are
    // inside the LDC's 1-16 MHz spec. 13.5 MHz was abandoned once before because it
    // coupled into the LC tank over the dupont harness and made L spiky — if that
    // returns, it is a ROUTING problem (guard/keep away from the coil), not a
    // reason to drop back below the 4x rule.
    reg [2:0] clkin_cnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) clkin_cnt <= 3'd0;
        else        clkin_cnt <= clkin_cnt + 3'd1;
    end
    assign ldc_clkin = (LDC_CLKIN_SEL == 2'd2) ? clkin_cnt[0] :   // 13.5 MHz
                       (LDC_CLKIN_SEL == 2'd1) ? clkin_cnt[1] :   //  6.75 MHz
                                                 clkin_cnt[2];    //  3.375 MHz

    //--------------------------------------------------- SPI byte engine (MODE 0)
    reg        spi_start, spi_busy, spi_done;
    reg [23:0] load_data, shift_out, spi_rx;
    reg [5:0]  total_bits, bit_cnt;
    reg [4:0]  div;
    reg        phase;   // 0 = next edge RISING (sample), 1 = next edge FALLING (advance)

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ldc_cs_n<=1'b1; ldc_sclk<=1'b0; ldc_sdi<=1'b0;   // SCLK idle LOW (Mode 0)
            spi_busy<=1'b0; spi_done<=1'b0; spi_rx<=24'h0;
            shift_out<=24'h0; bit_cnt<=6'd0; div<=5'd0; phase<=1'b0;
        end else begin
            spi_done <= 1'b0;
            if (spi_start && !spi_busy) begin
                ldc_cs_n  <= 1'b0;
                ldc_sclk  <= 1'b0;                 // idle LOW
                shift_out <= load_data;
                ldc_sdi   <= load_data[23];        // present MSB before 1st rising
                bit_cnt   <= total_bits;
                div       <= 5'd0;
                phase     <= 1'b0;
                spi_busy  <= 1'b1;
            end else if (spi_busy) begin
                if (div==HALF-1) begin
                    div <= 5'd0;
                    if (phase==1'b0) begin
                        ldc_sclk <= 1'b1;                  // RISING: sample MISO
                        spi_rx   <= {spi_rx[22:0], ldc_sdo};
                        phase    <= 1'b1;
                    end else begin
                        ldc_sclk <= 1'b0;                  // FALLING: advance MOSI
                        phase    <= 1'b0;
                        if (bit_cnt==6'd1) begin
                            spi_busy <= 1'b0;
                            ldc_cs_n <= 1'b1;
                            spi_done <= 1'b1;
                        end else begin
                            bit_cnt   <= bit_cnt - 6'd1;
                            shift_out <= {shift_out[22:0], 1'b0};
                            ldc_sdi   <= shift_out[22];
                        end
                    end
                end else div <= div + 5'd1;
            end
        end
    end

    //--------------------------------------------------- config write list
    reg [3:0] cfg_idx;
    reg [6:0] cfg_addr; reg [7:0] cfg_data;
    always @(*) begin
        case (cfg_idx)
            4'd0: begin cfg_addr=REG_START_CONF; cfg_data=VAL_SLEEP;    end // stop/sleep first
            4'd1: begin cfg_addr=REG_RP_SET;     cfg_data=VAL_RP_SET;   end
            4'd2: begin cfg_addr=REG_TC1;        cfg_data=VAL_TC1;      end
            4'd3: begin cfg_addr=REG_TC2;        cfg_data=VAL_TC2;      end
            4'd4: begin cfg_addr=REG_DIG_CONF;   cfg_data=VAL_DIG_CONF; end
            4'd5: begin cfg_addr=REG_ALT_CONF;   cfg_data=VAL_ALT_CONF; end
            4'd6: begin cfg_addr=REG_D_CONF;     cfg_data=VAL_D_CONF;   end
            default: begin cfg_addr=REG_START_CONF; cfg_data=VAL_ACTIVE; end // activate last
        endcase
    end
    localparam [3:0] CFG_COUNT = 4'd8;

    //--------------------------------------------------- data read addresses
    // Read STATUS(0x20) LAST, after the 4 data regs. Reading STATUS *before* the
    // RP/L data regs leaves DRDYB stuck and zeros RP/L; NOT reading it at all
    // leaves the registers stale/partial (dual read RP=0x0700 L=0xFF00). The
    // proven ldc_regcheck reads RP_L,RP_H,L_L,L_H,STATUS in this order.
    reg [2:0] data_idx;
    reg [6:0] data_addr;
    always @(*) begin
        case (data_idx)
            3'd0: data_addr=REG_RP_DATA_L;
            3'd1: data_addr=REG_RP_DATA_H;
            3'd2: data_addr=REG_L_DATA_L;
            3'd3: data_addr=REG_L_DATA_H;
            default: data_addr=REG_STATUS;
        endcase
    end
    reg [7:0] rp_lo, rp_hi, l_lo, l_hi;
    // STATUS(0x20) byte + POR auto-recovery. The device only gets configured once
    // at power-on, so ANY later brown-out/glitch leaves it parked in reset:
    // POR_READ(bit0)=1, DRDYB(bit6) never ready, RP/L read 0xFFFF forever — seen
    // on HW 2026-07-03 (ST=0x7D), and only a manual FPGA reset revived it.
    // Re-run the config list when POR_READ stays set, so it self-heals.
    reg [7:0] st_byte;
    reg [3:0] por_cnt;
    localparam [3:0] POR_RETRY = 4'd7;   // consecutive POR reads before reconfig

    //--------------------------------------------------- control FSM (race-free)
    // 16-bit transactions: WREG {0,addr}+data ; RREG {1,addr}+dummy -> spi_rx[7:0]
    localparam [4:0]
        S_POR  =5'd0,  S_CFG  =5'd1,  S_CFG_I=5'd2,  S_CFG_N=5'd3,
        S_ID_I =5'd4,  S_ID_C =5'd5,  S_RD_I =5'd6,  S_RD_C =5'd7,
        S_EMIT =5'd8,  S_DLY  =5'd9,  S_WAIT =5'd10;

    reg [4:0]  state, ret_state;
    reg [22:0] delay_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=S_POR; ret_state<=S_POR; delay_cnt<=23'd0;
            spi_start<=1'b0; load_data<=24'h0; total_bits<=6'd16;
            cfg_idx<=4'd0; data_idx<=3'd0;
            init_done<=1'b0; err_flag<=1'b0; data_valid<=1'b0; chip_id<=8'd0;
            rp_data<=16'd0; l_data<=16'd0;
            rp_lo<=8'd0; rp_hi<=8'd0; l_lo<=8'd0; l_hi<=8'd0;
            st_byte<=8'd0; por_cnt<=4'd0; status<=8'd0;
        end else begin
            spi_start  <= 1'b0;
            data_valid <= 1'b0;

            case (state)
            S_POR: begin
                if (delay_cnt==POR_DELAY) begin delay_cnt<=23'd0; state<=S_CFG; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            // ── walk config write list ───────────────────────────────────
            S_CFG: begin
                if (cfg_idx==CFG_COUNT) begin init_done<=1'b1; state<=S_ID_I; end
                else state<=S_CFG_I;
            end
            S_CFG_I: begin   // WREG {WRITE_BIT,cfg_addr}, cfg_data  (16 bits)
                load_data  <= {WRITE_BIT, cfg_addr, cfg_data, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_CFG_N; state <= S_WAIT;
            end
            S_CFG_N: begin cfg_idx <= cfg_idx + 4'd1; state <= S_CFG; end
            // ── CHIP_ID sanity (read 0x3F, expect 0xD4) ──────────────────
            S_ID_I: begin
                load_data  <= {READ_BIT, REG_CHIP_ID, 8'hFF, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_ID_C; state <= S_WAIT;
            end
            S_ID_C: begin
                chip_id  <= spi_rx[7:0];
                err_flag <= (spi_rx[7:0] != CHIP_ID_EXP);
                state    <= S_RD_I;
            end
            // ── read RP_L, RP_H, L_L, L_H ────────────────────────────────
            S_RD_I: begin
                load_data  <= {READ_BIT, data_addr, 8'hFF, 8'h00};
                total_bits <= 6'd16;
                spi_start  <= 1'b1; ret_state <= S_RD_C; state <= S_WAIT;
            end
            S_RD_C: begin
                case (data_idx)
                    3'd0: rp_lo <= spi_rx[7:0];
                    3'd1: rp_hi <= spi_rx[7:0];
                    3'd2: l_lo  <= spi_rx[7:0];
                    3'd3: l_hi  <= spi_rx[7:0];
                    default: st_byte <= spi_rx[7:0];   // STATUS(0x20)
                endcase
                if (data_idx==3'd4) begin data_idx<=3'd0; state<=S_EMIT; end
                else begin data_idx<=data_idx+3'd1; state<=S_RD_I; end
            end
            S_EMIT: begin
                delay_cnt <= 23'd0;
                status    <= st_byte;   // latch unconditionally: a POR-retry loop is
                                        // exactly the case worth seeing from outside
                if (st_byte[0]) begin           // POR_READ: device fell back to reset
                    if (por_cnt == POR_RETRY) begin
                        por_cnt   <= 4'd0;      // persistent -> reconfigure, emit nothing
                        cfg_idx   <= 4'd0;
                        init_done <= 1'b0;
                        state     <= S_CFG;
                    end else begin
                        por_cnt <= por_cnt + 4'd1;
                        state   <= S_DLY;
                    end
                end else begin
                    por_cnt    <= 4'd0;
                    rp_data    <= {rp_hi, rp_lo};
                    l_data     <= {l_hi, l_lo};
                    data_valid <= 1'b1;
                    state      <= S_DLY;
                end
            end
            S_DLY: begin     // ~1 kHz sample loop
                // Re-enter via S_ID_I so CHIP_ID is refreshed every loop (one extra
                // 16-bit transaction; the LDC's own conversion dominates the rate).
                if (delay_cnt==LOOP_DELAY) begin delay_cnt<=23'd0; state<=S_ID_I; end
                else delay_cnt<=delay_cnt+23'd1;
            end
            // ── shared wait: hold until the SPI transaction completes ─────
            S_WAIT: begin
                if (spi_done) state <= ret_state;
            end
            default: state <= S_POR;
            endcase
        end
    end
endmodule
